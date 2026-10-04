class_name TestSubject
extends CharacterBody3D
## Temporary stand-in for the player (test subject / decoy).
##
##   W      - move forward
##   S      - back away WITHOUT turning
##   A / D  - turn left / turn right  (strafe left / right while lock-on is active)
##   Q      - toggle lock-on: face the closest monster in group "stalker" that is
##            in front; with no monster in range the torch just points forward
##   F      - toggle the flashlight
##
## (Silent Hill 3-style controls, same scheme as the shared player in
## controls/godot_horror/player. E is left to the test room, which uses it
## for placing the Dummy / cubes.)
##
## This body owns the flashlight side of the light interaction: it decides
## whether the light actually hits the Stalker (cone + distance + occlusion)
## and pushes the result into Stalker.set_lit(). The Stalker itself knows
## nothing about lights.
##
## Teammates: this whole body can be swapped later. Contract:
##   - it stays in group "player" (the Stalker chases it)
##   - it stays out of group "dead" until it dies
##   - it implements die()
##   - it stays in group "light_source" and implements is_light_on() / is_held()
##     (the Seeker is attracted to light sources and attacks them)

signal died
## Emitted once when the subject is killed.

signal flashlight_toggled(is_on: bool)

@export_group("Movement")
@export var move_speed := 3.2
@export var gravity := 25.0
## How fast A / D turn the body (radians per second).
@export var turn_speed := 4.0

@export_group("Lock-on")
## How fast the body turns to face the locked-on monster (radians per second).
@export var lock_on_turn_speed := 4.0
## Monsters further away than this are ignored (meters).
@export var lock_on_range := 9.0
## Monsters must be within this front cone to be targetable (degrees).
@export var lock_on_cone_deg := 70.0
## Group holding the targetable monsters.
@export var lock_on_group := "stalker"

@export_group("Flashlight")
## "Am I lit" test radius (meters). Does not have to match the visual light.
@export var light_range := 12.0
## Half angle of the lit cone (degrees), measured from the light's -Z axis.
@export var light_half_angle := 26.0
## Height on the Stalker's body that must be lit for it to freeze.
@export var target_height := 0.9
## Collision layers that block light (room geometry).
@export_flags_3d_physics var occluder_mask := 1

var flashlight_is_on := true:
	set(value):
		if flashlight_is_on == value:
			return
		flashlight_is_on = value
		if value:
			$Light.light_energy = 4.0
		else:
			$Light.light_energy = 0.0
		flashlight_toggled.emit(value)

## While locked the subject cannot walk, but A/D still turn it so the
## flashlight can be aimed. Set by the test room when T is pressed.
var locked := false
## When false the subject ignores WASD completely (used while the test room
## is moving a ghost cube or the test is waiting).
var input_enabled := true

var _dead := false
var _lock_on := false
var _light_key_held := false
var _q_key_held := false
var _stalker: Stalker
var _fall_tween: Tween
var _spawn_position := Vector3.ZERO
var _body_material: StandardMaterial3D
var _body_albedo := Color.WHITE


func _ready() -> void:
	add_to_group("player")
	add_to_group("light_source")
	_spawn_position = global_position
	# Slight downward tilt; the light is a child, so it follows the body's facing.
	$Light.rotation.x = deg_to_rad(-10.0)
	# $Body is now the Dummy.fbx scene, which has its own materials, so there is
	# no single material to fade. A capsule stand-in with material_override still works.
	if $Body is GeometryInstance3D:
		_body_material = ($Body as GeometryInstance3D).material_override as StandardMaterial3D
	if _body_material:
		_body_albedo = _body_material.albedo_color


func _physics_process(delta: float) -> void:
	_handle_light_toggle()
	_handle_lock_on()
	if _dead:
		if _stalker:
			_stalker.set_lit(false)
		return
	_move(delta)
	_update_stalker_lit()


## ------------------------------------------------------------------ movement

## Freeze / unfreeze the subject's position. The spawn point moves to the
## current spot so a respawn after dying puts it back where it was locked.
func set_locked(value: bool) -> void:
	locked = value
	if value:
		_spawn_position = global_position
		velocity = Vector3.ZERO


## Silent Hill 3-style controls:
##   W - forward, S - back away (never turns the body), A / D - turn in place.
##   While lock-on is active, A / D strafe instead of turning, and the body
##   keeps facing the nearest targetable monster.
func _move(delta: float) -> void:
	var forward := -global_transform.basis.z
	var right := global_transform.basis.x

	var turn_input := 0.0
	var move_input := 0.0
	if input_enabled:
		if Input.is_action_pressed("move_left"):
			turn_input += 1.0
		if Input.is_action_pressed("move_right"):
			turn_input -= 1.0
		if Input.is_action_pressed("move_forward"):
			move_input += 1.0
		if Input.is_action_pressed("move_back"):
			move_input -= 1.0

	# A / D: turn while free, strafe while lock-on is active.
	var strafe_input := 0.0
	if _lock_on:
		strafe_input = -turn_input
	else:
		rotate_y(turn_input * turn_speed * delta)

	# W / S: forward / back. The test-room lock freezes walking but keeps
	# turning, so the torch can still be aimed while in place.
	if locked:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		var direction := forward * move_input + right * strafe_input
		if direction.length_squared() > 1.0:
			direction = direction.normalized()
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed

	velocity.y -= gravity * delta
	move_and_slide()

	# Lock-on: keep facing the closest targetable monster.
	if _lock_on:
		_face_lock_target(delta)


## Toggles lock-on with Q. No input action exists for it yet, so the raw key
## is polled (same pattern as _handle_light_toggle()).
func _handle_lock_on() -> void:
	var down := Input.is_key_pressed(KEY_Q)
	if down and not _q_key_held:
		_lock_on = not _lock_on
	_q_key_held = down


## Turns toward the closest targetable monster.
func _face_lock_target(delta: float) -> void:
	var target := _closest_monster_in_front()
	if target == null:
		return
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.001:
		return
	to_target = to_target.normalized()
	var forward := -global_transform.basis.z
	var angle := forward.angle_to(to_target)
	if angle < 0.005:
		return
	# Positive cross.y means the target is to the left.
	var side := forward.cross(to_target).y
	var step := minf(lock_on_turn_speed * delta, angle)
	rotate_y(step if side > 0.0 else -step)


## Nearest node in [lock_on_group] that is within [lock_on_range] m and in the
## front cone of [lock_on_cone_deg] degrees.
func _closest_monster_in_front() -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	var forward := -global_transform.basis.z
	var min_facing := cos(deg_to_rad(lock_on_cone_deg))
	for node in get_tree().get_nodes_in_group(lock_on_group):
		if not node is Node3D:
			continue
		var to_node: Vector3 = node.global_position - global_position
		var dist := to_node.length()
		if dist < 0.001 or dist > lock_on_range:
			continue
		if to_node.normalized().dot(forward) < min_facing:
			continue
		if dist < best_dist:
			best_dist = dist
			best = node
	return best


## ------------------------------------------------------------------ light

## Light source contract (used by the Seeker).
func is_light_on() -> bool:
	return flashlight_is_on and not _dead


## The torch is always carried by this body.
func is_held() -> bool:
	return true


func _handle_light_toggle() -> void:
	var down := Input.is_action_pressed("toggle_light")
	if down and not _light_key_held:
		flashlight_is_on = not flashlight_is_on
	_light_key_held = down


func _update_stalker_lit() -> void:
	if _stalker == null or not _stalker.is_inside_tree():
		_stalker = _find_stalker()
	if _stalker == null:
		return
	_stalker.set_lit(_is_stalker_lit())


func _find_stalker() -> Stalker:
	var found: Node = get_tree().get_first_node_in_group("stalker")
	return found if found is Stalker else null


## Is the Stalker currently inside our flashlight?
## Light check = cone + range + a raycast so walls cast real shadows.
func _is_stalker_lit() -> bool:
	if not flashlight_is_on or _stalker == null:
		return false
	var light := $Light
	var origin: Vector3 = light.global_position
	var direction: Vector3 = _stalker.global_position + Vector3(0, target_height, 0) - origin
	var distance := direction.length()
	if distance > light_range:
		return false
	direction /= distance
	# SpotLight3D shines along its -Z axis.
	var light_axis: Vector3 = -light.global_transform.basis.z
	if rad_to_deg(light_axis.angle_to(direction)) > light_half_angle:
		return false
	if _is_occluded(origin, _stalker.global_position + Vector3(0, target_height, 0)):
		return false
	return true


func _is_occluded(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = occluder_mask
	query.exclude = [self, _stalker]
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(query)
	return hit.size() > 0


## --------------------------------------------------------------------- death

func die(attacker_position: Vector3 = Vector3.INF) -> void:
	if _dead:
		return

	_dead = true
	died.emit()
	add_to_group("dead")
	velocity = Vector3.ZERO
	flashlight_is_on = false
	_lock_on = false
	set_physics_process(false)

	var body := $Body as Node3D

	# The body falls AWAY from the attacker.
	# Example: attacker hits from behind -> Dummy falls forward.
	var away := global_position - attacker_position
	away.y = 0.0

	if attacker_position == Vector3.INF or away.length_squared() < 0.001:
		# No hit direction supplied: fall forward according to the subject's facing.
		away = -global_transform.basis.z
		away.y = 0.0

	away = away.normalized()

	# Convert the world-space hit direction into the subject's local space.
	var local_away := global_transform.basis.inverse() * away
	local_away.y = 0.0
	local_away = local_away.normalized()

	# Local -Z is forward. Tilt the visible body around the horizontal axis
	# pointing across the fall direction.
	var fall_angle := PI * 0.5
	var fall_axis := Vector3(local_away.z, 0.0, -local_away.x).normalized()

	# Rotate the model around the correct horizontal axis. This means the
	# corpse always falls away from whoever hit it.
	var target_rotation := body.rotation
	target_rotation.x = fall_axis.x * fall_angle
	target_rotation.z = fall_axis.z * fall_angle

	_fall_tween = create_tween()
	_fall_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_fall_tween.parallel().tween_property(body, "rotation:x", target_rotation.x, 0.32)
	_fall_tween.parallel().tween_property(body, "rotation:z", target_rotation.z, 0.32)
	_fall_tween.parallel().tween_property(
		body,
		"position:y",
		body.position.y - 0.45,
		0.32
	)

	# Stay down long enough for the death pose to be visible.
	get_tree().create_timer(2.5).timeout.connect(_respawn, CONNECT_ONE_SHOT)


func _respawn() -> void:
	if not _dead:
		return

	if _fall_tween and _fall_tween.is_valid():
		_fall_tween.kill()

	var body := $Body as Node3D
	body.rotation = Vector3.ZERO
	body.position = Vector3.ZERO

	_dead = false
	remove_from_group("dead")
	rotation = Vector3.ZERO
	global_position = _spawn_position
	velocity = Vector3.ZERO
	flashlight_is_on = true
	set_physics_process(true)
	print("Test subject respawned at ", _spawn_position)
