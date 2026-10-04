class_name Stalker
extends CharacterBody3D
## The Stalker - a broken mannequin that chases its target, freezes when
## illuminated by light, and lunges when close enough to strike.
##
## The navigation agent is only asked "where should I go next"; the
## "Feel" parameters below are what make the answer arrive in a
## jerky, uneven, puppet-y way.
##
## Expected scene structure (see stalker.tscn):
##   Stalker (CharacterBody3D)
##   ├── Collision   (CollisionShape3D)
##   ├── Navigation  (NavigationAgent3D)
##   └── Model       (Node3D)
##       ├── Body    (temporary Mixamo mannequin scene, has AnimationPlayer)
##       └── Punch   (dummy attack model, hidden until it attacks)

signal player_killed(player: Node3D)
## Emitted when the Stalker strikes its target.

enum State { IDLE, CHASING, ATTACKING, FROZEN }

@export_group("Target")
## If no node in group "player" exists, fall back to this reference.
@export var target_fallback: Node3D
## Gravity used to keep the body planted on the floor.
@export var gravity := 25.0

@export_group("Navigation")
## How often the Stalker pushes a fresh target into the navigation agent.
@export var repath_interval := 0.25
## Don't repath if the target moved less than this many meters.
@export var repath_distance := 0.5

@export_group("Feel")
## Speed range sampled on every "lurch" (m/s). Wide range = uneven gait.
@export var lurch_speed_range := Vector2(0.35, 3.8)
## How long each lurch lasts. The Stalker stalls at the bottom of this range.
@export var lurch_interval_range := Vector2(0.18, 0.85)
## Random yaw offset (radians) applied to the path direction per lurch.
@export var heading_jitter := 0.4
## Yaw (radians) stepped per rotation "snap" of the model.
@export var snap_step_range := Vector2(0.2, 0.55)
## How often the model snaps to a new yaw.
@export var snap_interval_range := Vector2(0.08, 0.2)
## Chance that a snap overshoots the intended heading.
@export var overshoot_chance := 0.15
## How far an overshooting snap can swing past the target heading (radians).
@export var overshoot_range := Vector2(0.15, 0.6)

@export_group("Attack")
## Distance (meters) at which the Stalker abandons navigation and lunges.
@export var attack_range := 1.7
@export var lunge_speed := 4.6
@export var lunge_duration := 0.22
## How long the dummy punch model stays visible.
@export var punch_duration := 0.5

@export_group("Animation")
## Names of the animations inside the Body / Punch AnimationPlayers.
@export var walk_anim := "MonsterPSX_Rig|Walk_Nervous"
@export var punch_anim := "Take 001"
## The model's forward axis at zero rotation (local XZ), used for aiming.
@export var model_forward := Vector3(0, 0, 1)
## The real-world walk speed (m/s) of walk_anim, used to scale playback.
@export var walk_reference_speed := 2.0

var state: State = State.IDLE
## The Stalker waits (does nothing) until activate() is called, e.g. by the
## test room when T is pressed.
var active := false
## Whether the Stalker is currently in the player's light. Set externally.
var is_lit := false

var _player: Node3D
var _navigation: NavigationAgent3D
var _model: Node3D
var _walk_player: AnimationPlayer
var _punch_model: Node3D
var _punch_player: AnimationPlayer
var _facing := 0.0
var _lurch_speed := 0.0
var _lurch_time := 0.0
var _snap_time := 0.0
var _heading_bias := 0.0
var _repath_time := 0.0
var _repath_target := Vector3.ZERO
var _lunge_time := 0.0
var _spawn_transform := Transform3D.IDENTITY


func _find_animation_player(from_node: Node) -> AnimationPlayer:
	if from_node == null:
		return null

	var players: Array[Node] = from_node.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		return players[0] as AnimationPlayer

	return null

func _ready() -> void:
	add_to_group("stalker")
	_spawn_transform = global_transform
	_navigation = $Navigation
	_model = $Model
	_walk_player = _find_animation_player($Model/Body)
	if _walk_player == null:
		push_warning("Stalker: Missing AnimationPlayer on Model/Body")
	else:
		print("=== STALKER WALK ANIMATIONS ===")
		for animation_name in _walk_player.get_animation_list():
			print("  ", animation_name)

	_punch_model = $Model/Punch
	_punch_player = _find_animation_player($Model/Punch)
	if _punch_player == null:
		push_warning("Stalker: Missing AnimationPlayer on Model/Punch")
	else:
		print("=== STALKER PUNCH ANIMATIONS ===")
		for animation_name in _punch_player.get_animation_list():
			print("  ", animation_name)
	if _punch_player == null:
		push_warning("Stalker: Missing AnimationPlayer on Model/Punch")
	_punch_model.visible = false
	if _walk_player:
		_walk_player.animation_finished.connect(_on_walk_animation_finished)
	_roll_lurch()
	_roll_snap()


func _physics_process(delta: float) -> void:
	if not active:
		velocity = Vector3.ZERO
		if _walk_player:
			_walk_player.speed_scale = 0.0
		return
	_ensure_player()
	_update_illumination()
	match state:
		State.FROZEN:
			_update_frozen(delta)
		State.ATTACKING:
			_update_attacking(delta)
		_:
			_update_chasing(delta)


# ------------------------------------------------------------- activation

## Start the behaviour (chase / freeze in light / lunge).
func activate() -> void:
	active = true
	state = State.IDLE


## Stop and put the Stalker back where it started.
func deactivate() -> void:
	active = false
	state = State.IDLE
	is_lit = false
	velocity = Vector3.ZERO
	_player = null
	_lunge_time = 0.0
	_punch_model.visible = false
	if _punch_player:
		_punch_player.stop()
	if _walk_player:
		_walk_player.speed_scale = 0.0
	global_transform = _spawn_transform
	_facing = 0.0
	_model.rotation.y = 0.0


## Deactivate and put the Stalker down at a new spot (waits for activate()).
func relocate(pos: Vector3) -> void:
	deactivate()
	global_position = pos
	_spawn_transform = global_transform
	_navigation.target_position = pos


# --------------------------------------------------------------------- light

func set_lit(value: bool) -> void:
	is_lit = value


func _update_illumination() -> void:
	if is_lit and state == State.CHASING:
		state = State.FROZEN
		if _walk_player:
			_walk_player.speed_scale = 0.0
	elif not is_lit and state == State.FROZEN:
		state = State.CHASING
		if _walk_player:
			_walk_player.speed_scale = 1.0
		_roll_lurch()
		_roll_snap()


# ------------------------------------------------------------------ targeting

func _ensure_player() -> void:
	if _player == null or not _player.is_inside_tree():
		_player = _find_player()


func _find_player() -> Node3D:
	var candidates := get_tree().get_nodes_in_group("player")
	for candidate in candidates:
		if candidate is Node3D and not candidate.is_in_group("dead"):
			return candidate
	return target_fallback


func state_name() -> String:
	if not active:
		return "WAITING (press T)"
	match state:
		State.IDLE:
			return "IDLE"
		State.CHASING:
			return "CHASING"
		State.ATTACKING:
			return "ATTACKING"
		_:
			return "FROZEN (in light)"


# --------------------------------------------------------------------- chase

func _update_chasing(delta: float) -> void:
	if _player == null:
		state = State.IDLE
		velocity = Vector3.ZERO
		if _walk_player:
			_walk_player.speed_scale = 0.0
		return

	if state == State.IDLE:
		state = State.CHASING
	var to_player: Vector3 = _player.global_position - global_position
	to_player.y = 0.0
	if to_player.length() < attack_range:
		_enter_attacking()
		return

	_maybe_repath()
	var direction := _move_direction(to_player)
	_lurch(delta, direction)
	move_and_slide()
	_sync_walk_animation()


func _enter_attacking() -> void:
	state = State.ATTACKING
	if _walk_player:
		_walk_player.speed_scale = 0.0
	_lunge_time = lunge_duration
	if _player:
		var to_player: Vector3 = _player.global_position - global_position
		_facing = _yaw_to(to_player)
		_model.rotation.y = _facing


# ------------------------------------------------------------------- attack

func _update_attacking(delta: float) -> void:
	_lunge_time -= delta
	if _player == null:
		state = State.IDLE
		velocity = Vector3.ZERO
		return
	var to_player: Vector3 = _player.global_position - global_position
	to_player.y = 0.0
	_facing = _yaw_to(to_player)
	_model.rotation.y = _facing
	velocity = Vector3.ZERO
	if to_player.length() > 0.05:
		velocity += to_player.normalized() * lunge_speed
	velocity.y -= gravity * delta
	move_and_slide()
	if _lunge_time <= 0.0:
		_strike()


func _strike() -> void:
	state = State.IDLE
	velocity = Vector3.ZERO
	_play_punch()
	var victim := _player
	if victim:
		if victim.has_method("die"):
			victim.die(global_position)
		player_killed.emit(victim)
	_player = null


func _play_punch() -> void:
	_punch_model.visible = true
	if _punch_player:
		var animation_name := StringName(punch_anim)
		if _punch_player.has_animation(animation_name):
			_punch_player.play(animation_name)
		else:
			push_warning("Stalker: Punch animation '%s' not found." % punch_anim)
	get_tree().create_timer(punch_duration).timeout.connect(
		func() -> void:
			_punch_model.visible = false
			if _punch_player:
				_punch_player.stop(),
		CONNECT_ONE_SHOT
	)


# ------------------------------------------------------------------ frozen

func _update_frozen(delta: float) -> void:
	# Snap the velocity to zero in a single step; the broken mannequin does
	# not glide to a stop.
	velocity = Vector3.ZERO
	move_and_slide()


# --------------------------------------------------------------- navigation

func _maybe_repath() -> void:
	_repath_time += get_physics_process_delta_time()
	var target: Vector3 = _player.global_position
	var moved_far := (target - _repath_target).length() > repath_distance
	if _repath_time >= repath_interval or moved_far:
		_repath_time = 0.0
		_repath_target = target
		_navigation.target_position = target


## Where the navigation says to go next, jittered so the path never looks
## clean. Falls back to a straight line to the player if no path is found.
func _move_direction(fallback_to_player: Vector3) -> Vector3:
	var direction := fallback_to_player.normalized()
	# Follow the path even when the target sits just off the navmesh (next to an
	# obstacle); the path then leads to the closest reachable point.
	if _navigation.is_target_reachable() or not _navigation.is_navigation_finished():
		var to_next: Vector3 = _navigation.get_next_path_position() - global_position
		to_next.y = 0.0
		if to_next.length() > 0.05:
			direction = to_next.normalized()
	# Per-lurch heading jitter, in radians.
	return direction.rotated(Vector3.UP, _heading_bias)


# ------------------------------------------------------------------- feel

func _roll_lurch() -> void:
	_lurch_time = randf_range(lurch_interval_range.x, lurch_interval_range.y)
	_lurch_speed = randf_range(lurch_speed_range.x, lurch_speed_range.y)
	_heading_bias = randf_range(-heading_jitter, heading_jitter)


func _roll_snap() -> void:
	_snap_time = randf_range(snap_interval_range.x, snap_interval_range.y)


func _lurch(delta: float, direction: Vector3) -> void:
	_lurch_time -= delta
	if _lurch_time <= 0.0:
		_roll_lurch()
	velocity = direction * _lurch_speed
	velocity.y -= gravity * delta
	_snap_rotation(delta, direction)


## The model does not turn smoothly: it snaps toward the heading in coarse
## increments and sometimes over-rotates.
func _snap_rotation(delta: float, move_direction: Vector3) -> void:
	_snap_time -= delta
	if _snap_time > 0.0:
		return
	_roll_snap()
	var target_yaw := _yaw_to(move_direction)
	var diff := wrapf(target_yaw - _facing, -PI, PI)
	if absf(diff) < 0.02:
		return
	var direction_sign := 1.0 if diff >= 0.0 else -1.0
	var step := direction_sign * minf(absf(diff), randf_range(snap_step_range.x, snap_step_range.y))
	if randf() < overshoot_chance:
		step += direction_sign * randf_range(overshoot_range.x, overshoot_range.y)
	_facing = wrapf(_facing + step, -PI, PI)
	_model.rotation.y = _facing


## Yaw rotation that makes `model_forward` point at `direction`.
func _yaw_to(direction: Vector3) -> float:
	var d: Vector3 = direction
	d.y = 0.0
	if d.length() < 0.001:
		return _facing
	d = d.normalized()
	var forward: Vector3 = model_forward
	forward.y = 0.0
	if forward.length() < 0.001:
		return _facing
	forward = forward.normalized()
	return -atan2(d.cross(forward).y, d.dot(forward))


# --------------------------------------------------------------- animation

func _sync_walk_animation() -> void:
	if _walk_player == null:
		return

	var animation_name := StringName(walk_anim)

	if not _walk_player.has_animation(animation_name):
		push_warning(
			"Stalker: Walk animation '%s' is not present in Body AnimationPlayer."
			% walk_anim
		)
		return

	if not _walk_player.is_playing() or _walk_player.current_animation != animation_name:
		_walk_player.play(animation_name)

	_walk_player.speed_scale = clampf(
		_lurch_speed / maxf(walk_reference_speed, 0.1),
		0.25,
		2.5
	)


func _on_walk_animation_finished(_animation: StringName) -> void:
	# Keep the walk cycle going while chasing; otherwise leave it still.
	if state == State.CHASING:
		if _walk_player:
			_walk_player.play(walk_anim)
