class_name TestSubject
extends CharacterBody3D
## Temporary stand-in for the player (test subject / decoy).
##
##   WASD - move
##   F    - toggle the flashlight
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

signal died
## Emitted once when the subject is killed.

signal flashlight_toggled(is_on: bool)

@export_group("Movement")
@export var move_speed := 3.2
@export var gravity := 25.0
## How fast the body turns toward the move direction (higher = snappier).
@export var turn_speed := 12.0

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

## While locked the subject cannot walk, but WASD still turns it so the
## flashlight can be aimed. Set by the test room when T is pressed.
var locked := false
## When false the subject ignores WASD completely (used while the test room
## is moving a ghost cube or the test is waiting).
var input_enabled := true

var _dead := false
var _light_key_held := false
var _stalker: Stalker
var _fall_tween: Tween
var _spawn_position := Vector3.ZERO
var _body_material: StandardMaterial3D
var _body_albedo := Color.WHITE


func _ready() -> void:
	add_to_group("player")
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


func _move(delta: float) -> void:
	# Camera-relative input (fixed camera, Resident Evil style): pressing a
	# direction turns the body toward it and walks that way. S turns around
	# and walks toward the camera instead of back-pedalling.
	var input := Vector2.ZERO
	if input_enabled:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var move_dir := Vector3.ZERO
	var cam := get_viewport().get_camera_3d()
	if input.length() > 0.01 and cam:
		var right := cam.global_transform.basis.x
		right.y = 0.0
		right = right.normalized()
		var back := cam.global_transform.basis.z
		back.y = 0.0
		back = back.normalized()
		move_dir = (right * input.x + back * input.y).normalized()
	elif input.length() > 0.01:
		move_dir = Vector3(input.x, 0.0, input.y).normalized()

	if move_dir != Vector3.ZERO:
		# Turn toward the move direction (the model's front is -Z).
		var target_yaw := atan2(-move_dir.x, -move_dir.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))
		if not locked:
			velocity.x = move_dir.x * move_speed
			velocity.z = move_dir.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 12.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 12.0 * delta)
	if locked:
		velocity.x = 0.0
		velocity.z = 0.0
	velocity.y -= gravity * delta
	move_and_slide()


## ------------------------------------------------------------------ light

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

func die() -> void:
	if _dead:
		return
	_dead = true
	died.emit()
	add_to_group("dead")
	velocity = Vector3.ZERO
	flashlight_is_on = false
	# Fall face-first like a dropped prop.
	_fall_tween = create_tween()
	_fall_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_fall_tween.parallel().tween_property(self, "rotation:x", -PI * 0.5, 0.4)
	if _body_material:
		var faded := Color(_body_albedo.r, _body_albedo.g, _body_albedo.b, 0.0)
		_fall_tween.parallel().tween_property(_body_material, "albedo_color", faded, 0.4)
	# Respawn after a short delay so the behaviour can be watched again.
	get_tree().create_timer(2.5).timeout.connect(_respawn, CONNECT_ONE_SHOT)


func _respawn() -> void:
	if not _dead:
		return
	if _fall_tween and _fall_tween.is_valid():
		_fall_tween.kill()
	_dead = false
	remove_from_group("dead")
	rotation = Vector3.ZERO
	global_position = _spawn_position
	velocity = Vector3.ZERO
	if _body_material:
		_body_material.albedo_color = _body_albedo
	flashlight_is_on = true
	print("Test subject respawned at ", _spawn_position)
