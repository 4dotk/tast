class_name Stalker
extends CharacterBody3D
## The Stalker - a broken mannequin that screams when it first notices its
## target, chases it, freezes when illuminated by light, and lunges when close
## enough to strike.
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
##       ├── Body    (Mixamo/rig scene, has AnimationPlayer; walk, scream and
##       │            attack animations all play here)
##       └── Punch   (optional dummy attack model, hidden until it strikes)

## Emitted when the Stalker strikes its target.
signal player_killed(player: Node3D)

enum State { IDLE, SCREAMING, CHASING, ATTACKING, FROZEN }

@export_group("Target")
## If no node in group "player" exists, fall back to this reference.
@export var target_fallback: Node3D
## Distance (meters) at which the Stalker first notices the player and
## screams. 0 = notices the player immediately.
@export var sight_range := 0.0
## Gravity used to keep the body planted on the floor.
@export var gravity := 25.0

@export_group("Navigation")
## How often the Stalker pushes a fresh target into the navigation agent.
@export var repath_interval := 0.25
## Don't repath if the target moved less than this many meters.
@export var repath_distance := 0.5

@export_group("Feel")
## Constant chase speed (m/s). The jerkiness comes from the heading jitter and
## rotation snaps below, not from speed changes.
@export var move_speed := 3.6
## How long each lurch (one heading jitter) lasts.
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
@export var lunge_speed := 5.6
## How long (seconds) the forward lunge movement lasts from the start of the attack.
@export var lunge_duration := 0.5
## Seconds after the attack starts when the hit lands and the player dies.
## The attack clip is ~1.2s long and keeps playing after the strike.
@export var strike_delay := 0.6
## Set true to also show the old dummy Punch model on strike.
@export var use_punch_model := false
## How long the dummy punch model stays visible.
@export var punch_duration := 0.5

@export_group("Animation")
## Animation names. Played on Model/Body unless noted. A name without the
## library prefix (e.g. "Scream_lol") also matches "MonsterPSX_Rig|Scream_lol".
@export var walk_anim := "MonsterPSX_Rig|Run_Frantic"
@export var scream_anim := "MonsterPSX_Rig|Scream_lol"
@export var attack_anim := "MonsterPSX_Rig|Attack_Lunge"
## Animation played on the dummy Punch model (only if use_punch_model).
@export var punch_anim := "MonsterPSX_Rig|Attack_Lunge"
## The model's forward axis at zero rotation (local XZ), used for aiming.
@export var model_forward := Vector3(0, 0, 1)
## The real-world speed (m/s) of walk_anim, used to scale playback.
@export var walk_reference_speed := 3.0

## Print every animation found on Body / Punch at startup.
@export var debug_print_animations := false

var state: State = State.IDLE
## The Stalker waits (does nothing) until activate() is called, e.g. by the
## test room when T is pressed.
var active := false
## Whether the Stalker is currently in the player's light. Set externally.
var is_lit := false

var _player: Node3D
var _navigation: NavigationAgent3D
var _model: Node3D
var _body_player: AnimationPlayer
var _punch_model: Node3D
var _punch_player: AnimationPlayer

# Animation names resolved against the AnimationPlayers in _ready().
var _walk_name := &""
var _scream_name := &""
var _attack_name := &""
var _punch_name := &""

var _facing := 0.0
var _lurch_time := 0.0
var _snap_time := 0.0
var _heading_bias := 0.0
var _repath_time := 0.0
var _repath_target := Vector3.ZERO
var _attack_time := 0.0
var _scream_time := 0.0
var _has_screamed := false
var _spawn_transform := Transform3D.IDENTITY


func _ready() -> void:
	add_to_group("stalker")
	add_to_group("enemies")  # Player lock-on searches this group.
	_spawn_transform = global_transform
	_navigation = $Navigation
	_model = $Model
	_punch_model = $Model/Punch
	_punch_model.visible = false

	_body_player = _find_animation_player($Model/Body)
	_punch_player = _find_animation_player(_punch_model)
	if _body_player == null:
		push_warning("Stalker: Missing AnimationPlayer on Model/Body")
	else:
		_walk_name = _resolve_anim(_body_player, walk_anim, "walk")
		_scream_name = _resolve_anim(_body_player, scream_anim, "scream")
		_attack_name = _resolve_attack_anim()
		_body_player.animation_finished.connect(_on_body_animation_finished)
	if use_punch_model:
		if _punch_player == null:
			push_warning("Stalker: Missing AnimationPlayer on Model/Punch")
		else:
			_punch_name = _resolve_anim(_punch_player, punch_anim, "punch")

	if debug_print_animations:
		_print_animations("BODY", _body_player)
		_print_animations("PUNCH", _punch_player)

	_reset_feel_timers()


func _physics_process(delta: float) -> void:
	if not active:
		velocity = Vector3.ZERO
		_pause_body_anim()
		return
	_ensure_player()
	_update_illumination()
	match state:
		State.FROZEN:
			_update_frozen()
		State.SCREAMING:
			_update_screaming(delta)
		State.ATTACKING:
			_update_attacking(delta)
		_:
			_update_chasing(delta)


# --------------------------------------------------------------- activation

## Start the behaviour (scream / chase / freeze in light / lunge).
func activate() -> void:
	active = true
	state = State.FROZEN if is_lit else State.IDLE
	if state == State.FROZEN:
		velocity = Vector3.ZERO
		_pause_body_anim()


## Stop and put the Stalker back where it started.
func deactivate() -> void:
	active = false
	state = State.IDLE
	is_lit = false
	velocity = Vector3.ZERO
	_player = null
	_attack_time = 0.0
	_scream_time = 0.0
	_has_screamed = false
	_hide_punch_model()
	_pause_body_anim()
	global_transform = _spawn_transform
	_facing = 0.0
	_model.rotation.y = 0.0


## Deactivate and put the Stalker down at a new spot (waits for activate()).
func relocate(pos: Vector3) -> void:
	deactivate()
	global_position = pos
	_spawn_transform = global_transform
	_navigation.target_position = pos


# -------------------------------------------------------------------- light

## Single authority for illumination state.
func set_lit(value: bool) -> void:
	if is_lit == value:
		return
	is_lit = value
	if not active:
		return

	if is_lit:
		# Light always wins, including during the scream and the lunge.
		state = State.FROZEN
		velocity = Vector3.ZERO
		_attack_time = 0.0
		_scream_time = 0.0
		_pause_body_anim()
	elif state == State.FROZEN:
		state = State.CHASING
		if _body_player:
			_body_player.speed_scale = 1.0
		_reset_feel_timers()


## Keeps state in sync if is_lit was changed directly instead of via set_lit().
func _update_illumination() -> void:
	if is_lit and state != State.FROZEN:
		is_lit = false  # Let set_lit() see the change and apply it.
		set_lit(true)
	elif not is_lit and state == State.FROZEN:
		is_lit = true
		set_lit(false)


# ---------------------------------------------------------------- targeting

func _ensure_player() -> void:
	if _player == null or not _player.is_inside_tree():
		_player = _find_player()


func _find_player() -> Node3D:
	for candidate in get_tree().get_nodes_in_group("player"):
		if candidate is Node3D and not candidate.is_in_group("dead"):
			return candidate
	return target_fallback


func _can_see_player() -> bool:
	if _player == null:
		return false
	return sight_range <= 0.0 or global_position.distance_to(_player.global_position) <= sight_range


## Flat (XZ) vector from the Stalker to the player.
func _to_player_flat() -> Vector3:
	var to_player := _player.global_position - global_position
	to_player.y = 0.0
	return to_player


func _face_player() -> void:
	if _player:
		_facing = _yaw_to(_player.global_position - global_position)
		_model.rotation.y = _facing


func state_name() -> String:
	if not active:
		return "WAITING (press T)"
	match state:
		State.IDLE:
			return "IDLE"
		State.SCREAMING:
			return "SCREAMING"
		State.CHASING:
			return "CHASING"
		State.ATTACKING:
			return "ATTACKING"
		_:
			return "FROZEN (in light)"


# -------------------------------------------------------------------- chase

func _update_chasing(delta: float) -> void:
	if _player == null:
		state = State.IDLE
		velocity = Vector3.ZERO
		# After a strike _player is cleared; let the attack clip finish playing.
		if _body_player and _body_player.current_animation != _attack_name:
			_pause_body_anim()
		return

	if state == State.IDLE:
		if not _has_screamed:
			# Stay put until the player is noticed for the first time.
			if _can_see_player():
				_enter_screaming()
			return
		state = State.CHASING

	var to_player := _to_player_flat()
	if to_player.length() < attack_range:
		_enter_attacking()
		return

	_maybe_repath(delta)
	var direction := _move_direction(to_player)
	_lurch(delta, direction)
	move_and_slide()
	_sync_walk_animation()


# ------------------------------------------------------------------- scream

func _enter_screaming() -> void:
	_has_screamed = true
	velocity = Vector3.ZERO
	_face_player()
	if _scream_name == &"":
		state = State.CHASING  # No scream clip available; skip straight to the chase.
		return
	state = State.SCREAMING
	_scream_time = _play_body_anim(_scream_name)


func _update_screaming(delta: float) -> void:
	_scream_time -= delta
	_face_player()
	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y -= gravity * delta
	move_and_slide()
	if _scream_time <= 0.0:
		state = State.CHASING
		_reset_feel_timers()


# ------------------------------------------------------------------- attack

func _enter_attacking() -> void:
	state = State.ATTACKING
	_attack_time = 0.0
	_face_player()
	if _attack_name != &"":
		_play_body_anim(_attack_name)
	else:
		_pause_body_anim()


func _update_attacking(delta: float) -> void:
	_attack_time += delta
	if _player == null:
		state = State.IDLE
		velocity = Vector3.ZERO
		return

	var to_player := _to_player_flat()
	_face_player()
	velocity = Vector3.ZERO
	# Only the first part of the attack moves forward; the rest is the swing.
	if _attack_time < lunge_duration and to_player.length() > 0.05:
		velocity = to_player.normalized() * lunge_speed
	velocity.y -= gravity * delta
	move_and_slide()
	if _attack_time >= strike_delay:
		_strike()


func _strike() -> void:
	state = State.IDLE
	velocity = Vector3.ZERO
	_show_punch_model()
	var victim := _player
	_player = null
	if victim:
		if victim.has_method("die"):
			victim.die(global_position)
		player_killed.emit(victim)


func _show_punch_model() -> void:
	if not use_punch_model:
		return
	_punch_model.visible = true
	if _punch_player and _punch_name != &"":
		_punch_player.play(_punch_name)
	get_tree().create_timer(punch_duration).timeout.connect(_hide_punch_model, CONNECT_ONE_SHOT)


func _hide_punch_model() -> void:
	_punch_model.visible = false
	if _punch_player:
		_punch_player.stop()


# ------------------------------------------------------------------- frozen

func _update_frozen() -> void:
	# Velocity snaps to zero in a single step; the broken mannequin does not
	# glide to a stop.
	velocity = Vector3.ZERO
	move_and_slide()


# --------------------------------------------------------------- navigation

func _maybe_repath(delta: float) -> void:
	_repath_time += delta
	var target := _player.global_position
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
		var to_next := _navigation.get_next_path_position() - global_position
		to_next.y = 0.0
		if to_next.length() > 0.05:
			direction = to_next.normalized()
	# Per-lurch heading jitter, in radians.
	return direction.rotated(Vector3.UP, _heading_bias)


# --------------------------------------------------------------------- feel

func _reset_feel_timers() -> void:
	_roll_lurch()
	_roll_snap()


func _roll_lurch() -> void:
	_lurch_time = randf_range(lurch_interval_range.x, lurch_interval_range.y)
	_heading_bias = randf_range(-heading_jitter, heading_jitter)


func _roll_snap() -> void:
	_snap_time = randf_range(snap_interval_range.x, snap_interval_range.y)


func _lurch(delta: float, direction: Vector3) -> void:
	_lurch_time -= delta
	if _lurch_time <= 0.0:
		_roll_lurch()
	velocity = direction * move_speed
	velocity.y -= gravity * delta
	_snap_rotation(delta, direction)


## The model does not turn smoothly: it snaps toward the heading in coarse
## increments and sometimes over-rotates.
func _snap_rotation(delta: float, move_direction: Vector3) -> void:
	_snap_time -= delta
	if _snap_time > 0.0:
		return
	_roll_snap()
	var diff := wrapf(_yaw_to(move_direction) - _facing, -PI, PI)
	if absf(diff) < 0.02:
		return
	var direction_sign := signf(diff)
	var step := direction_sign * minf(absf(diff), randf_range(snap_step_range.x, snap_step_range.y))
	if randf() < overshoot_chance:
		step += direction_sign * randf_range(overshoot_range.x, overshoot_range.y)
	_facing = wrapf(_facing + step, -PI, PI)
	_model.rotation.y = _facing


## Yaw rotation that makes `model_forward` point at `direction`.
func _yaw_to(direction: Vector3) -> float:
	var d := Vector3(direction.x, 0.0, direction.z)
	var forward := Vector3(model_forward.x, 0.0, model_forward.z)
	if d.length() < 0.001 or forward.length() < 0.001:
		return _facing
	d = d.normalized()
	forward = forward.normalized()
	return -atan2(d.cross(forward).y, d.dot(forward))


# ---------------------------------------------------------------- animation

func _find_animation_player(from_node: Node) -> AnimationPlayer:
	if from_node == null:
		return null
	var players := from_node.find_children("*", "AnimationPlayer", true, false)
	return players[0] as AnimationPlayer if not players.is_empty() else null


## Finds `anim_name` on the player, also matching it with a library prefix
## (e.g. "Scream_lol" matches "MonsterPSX_Rig|Scream_lol"). Returns &"" and
## warns once if there is no match.
func _resolve_anim(player: AnimationPlayer, anim_name: String, label: String) -> StringName:
	var found := _find_anim(player, anim_name)
	if found == &"":
		push_warning("Stalker: %s animation '%s' not found." % [label, anim_name])
	return found


## Same as _resolve_anim() but silent.
func _find_anim(player: AnimationPlayer, anim_name: String) -> StringName:
	if player == null:
		return &""
	if player.has_animation(anim_name):
		return StringName(anim_name)
	for candidate in player.get_animation_list():
		if String(candidate).ends_with("|" + anim_name):
			return candidate
	return &""


## The attack clip is looked up on Body first. If it only exists on the old
## dummy Punch model, it is copied into Body's AnimationPlayer so the Stalker
## itself can play it (works when both models share the same rig).
func _resolve_attack_anim() -> StringName:
	var found := _find_anim(_body_player, attack_anim)
	if found != &"":
		return found

	var source := _find_anim(_punch_player, attack_anim)
	if source == &"":
		push_warning("Stalker: attack animation '%s' not found on Body or Punch." % attack_anim)
		return &""

	if not _body_player.has_animation_library(&""):
		_body_player.add_animation_library(&"", AnimationLibrary.new())
	var library := _body_player.get_animation_library(&"")
	if library.add_animation(source, _punch_player.get_animation(source).duplicate()) != OK:
		push_warning("Stalker: could not copy attack animation '%s' to Body." % source)
		return &""
	return source


## Plays a Body animation at normal speed and returns its length in seconds.
func _play_body_anim(anim_name: StringName) -> float:
	_body_player.speed_scale = 1.0
	_body_player.play(anim_name)
	return _body_player.get_animation(anim_name).length


func _pause_body_anim() -> void:
	if _body_player:
		_body_player.speed_scale = 0.0


func _sync_walk_animation() -> void:
	if _body_player == null or _walk_name == &"":
		return
	if not _body_player.is_playing() or _body_player.current_animation != _walk_name:
		_body_player.play(_walk_name)
	_body_player.speed_scale = clampf(move_speed / maxf(walk_reference_speed, 0.1), 0.25, 2.5)


## Keep the walk cycle going while chasing; otherwise leave it still.
func _on_body_animation_finished(_animation: StringName) -> void:
	if state == State.CHASING and _walk_name != &"":
		_body_player.play(_walk_name)


func _print_animations(label: String, player: AnimationPlayer) -> void:
	if player == null:
		return
	print("=== STALKER %s ANIMATIONS ===" % label)
	for animation_name in player.get_animation_list():
		print("  ", animation_name)
