class_name Player
extends CharacterBody3D
## Silent Hill 3-style player controls.
##
## The Player is a character. The flashlight is a separate physical object.
##
## W / S : move forward / back
## A / D : turn, or strafe while locked on
## Q     : toggle lock-on (needs an enemy in front of you)
## E     : interact, or drop/pick up the flashlight
## F     : flashlight on/off (only while you are holding it)

const MOVE_SPEED := 4.0
const TURN_SPEED := 2.5
const LOCK_TURN_SPEED := 7.0
## An enemy must be this close (and in front) to be locked onto...
const ENEMY_RANGE := 9.0
const ENEMY_CONE_DEG := 90.0
## ...but once locked, it is only lost beyond this distance (no flicker at the edge).
const LOCK_BREAK_RANGE := 13.0
const INTERACT_RANGE := 1.8
const INTERACT_FACING := 0.3
const FLASHLIGHT_PICKUP_RANGE := 2.0
const FLASHLIGHT_DROP_DISTANCE := 0.7
const GRAVITY := 25.0

@export var flashlight_scene: PackedScene = preload(
	"res://entities/props/flashlight/flashlight.tscn"
)

## How long (seconds) the Player stays dead before respawning.
@export var respawn_delay := 2.5

@onready var _flashlight_socket: Node3D = $FlashlightSocket

var _flashlight: Flashlight
var _lock_target: Node3D
var _dead := false
var _spawn_transform := Transform3D.IDENTITY

signal died
## Emitted when lock-on acquires a target, or with null when it is released.
signal lock_target_changed(target: Node3D)


func _ready() -> void:
	add_to_group("player")
	_spawn_transform = global_transform

	_ensure_flashlight()


func _ensure_flashlight() -> void:
	if is_instance_valid(_flashlight):
		return

	# Reuse the flashlight already authored in player.tscn.
	# If an old scene accidentally contains duplicates, keep the first one.
	for child in _flashlight_socket.get_children():
		if not child is Flashlight:
			continue

		if _flashlight == null:
			_flashlight = child as Flashlight
		else:
			child.queue_free()

	if is_instance_valid(_flashlight):
		_flashlight.set_held(true)
		return

	# Only create one if the scene does not already contain one.
	_flashlight = flashlight_scene.instantiate() as Flashlight
	if _flashlight == null:
		push_error("Failed to instantiate the Flashlight scene.")
		return

	_flashlight.name = "Flashlight"
	_flashlight_socket.add_child(_flashlight)
	_flashlight.transform = Transform3D.IDENTITY
	_flashlight.set_held(true)


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return

	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	match key_event.keycode:
		KEY_Q:
			_toggle_lock_on()

		KEY_F:
			# You can only switch the torch while you are holding it.
			if is_instance_valid(_flashlight) and _flashlight.is_held():
				_flashlight.toggle()

		KEY_E:
			_try_interact()


func _physics_process(delta: float) -> void:
	if _dead:
		return

	_update_lock_target()
	_handle_movement(delta)

	if _lock_target != null:
		_face_lock_target(delta)


func _handle_movement(delta: float) -> void:
	var forward: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x

	var turn_input := 0.0
	if Input.is_key_pressed(KEY_A):
		turn_input += 1.0
	if Input.is_key_pressed(KEY_D):
		turn_input -= 1.0

	var strafe_input := 0.0
	if _lock_target != null:
		strafe_input = -turn_input
	else:
		rotate_y(turn_input * TURN_SPEED * delta)

	var move_input := 0.0
	if Input.is_key_pressed(KEY_W):
		move_input += 1.0
	if Input.is_key_pressed(KEY_S):
		move_input -= 1.0

	var direction: Vector3 = forward * move_input + right * strafe_input
	if direction.length_squared() > 1.0:
		direction = direction.normalized()

	velocity.x = direction.x * MOVE_SPEED
	velocity.z = direction.z * MOVE_SPEED

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta

	move_and_slide()


# ------------------------------------------------------------------ lock-on

func is_locked_on() -> bool:
	return _lock_target != null


func get_lock_target() -> Node3D:
	return _lock_target


func _toggle_lock_on() -> void:
	if _lock_target != null:
		_set_lock_target(null)
		return

	# Only lock if there is really something to lock onto, otherwise A/D
	# would strafe with nothing to face.
	var target := _closest_in_front(
		"enemies",
		ENEMY_RANGE,
		cos(deg_to_rad(ENEMY_CONE_DEG))
	)
	if target == null:
		print("Lock-on: no enemy in range / in front of the player.")
		return

	_set_lock_target(target)


func _set_lock_target(target: Node3D) -> void:
	if _lock_target == target:
		return

	_lock_target = target
	lock_target_changed.emit(target)


## The lock is sticky: it stays on the same enemy until you press Q again,
## the enemy goes away, or it gets farther than LOCK_BREAK_RANGE.
func _update_lock_target() -> void:
	if _lock_target == null:
		return

	if (
		not is_instance_valid(_lock_target)
		or not _lock_target.is_inside_tree()
		or _lock_target.is_in_group("dead")
		or _lock_target.global_position.distance_to(global_position) > LOCK_BREAK_RANGE
	):
		_set_lock_target(null)


func _face_lock_target(delta: float) -> void:
	var to_target: Vector3 = _lock_target.global_position - global_position
	to_target.y = 0.0

	if to_target.length_squared() < 0.001:
		return

	to_target = to_target.normalized()

	var forward: Vector3 = -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()

	var angle := forward.angle_to(to_target)
	if angle < 0.005:
		return

	var side := forward.cross(to_target).y
	var step := minf(LOCK_TURN_SPEED * delta, angle)

	rotate_y(step if side > 0.0 else -step)


func _closest_in_front(
	group: String,
	max_dist: float,
	min_facing: float
) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	var forward: Vector3 = -global_transform.basis.z

	for node in get_tree().get_nodes_in_group(group):
		if not node is Node3D or node == self:
			continue

		var node_3d := node as Node3D
		var to_node: Vector3 = node_3d.global_position - global_position
		var dist: float = to_node.length()

		if dist < 0.001 or dist > max_dist:
			continue

		if to_node.normalized().dot(forward) < min_facing:
			continue

		if dist < best_dist:
			best_dist = dist
			best = node_3d

	return best


func _try_interact() -> void:
	var target := _closest_in_front(
		"interactables",
		INTERACT_RANGE,
		INTERACT_FACING
	)

	if target != null and target.has_method("interact"):
		target.interact(self)
		return

	if not is_instance_valid(_flashlight):
		return

	if _flashlight.is_held():
		_drop_flashlight()
	elif _flashlight.global_position.distance_to(global_position) <= FLASHLIGHT_PICKUP_RANGE:
		_pick_up_flashlight()


func _drop_flashlight() -> void:
	var world := get_parent()
	if world == null:
		return

	var drop_transform := _flashlight.global_transform
	drop_transform.origin = (
		global_position
		+ (-global_transform.basis.z) * FLASHLIGHT_DROP_DISTANCE
	)
	drop_transform.origin.y = _flashlight.dropped_height
	# Lay it level: while held, the socket may tilt the torch toward the floor.
	# (The socket's own yaw of 90 degrees makes the torch point forward.)
	drop_transform.basis = global_transform.basis * Basis(Vector3.UP, PI * 0.5)

	_flashlight.reparent(world, true)
	_flashlight.global_transform = drop_transform
	_flashlight.set_held(false)


func _pick_up_flashlight() -> void:
	_flashlight.reparent(_flashlight_socket, true)
	_flashlight.transform = Transform3D.IDENTITY
	_flashlight.set_held(true)


func is_flashlight_on() -> bool:
	return is_instance_valid(_flashlight) and _flashlight.is_light_on()


func get_flashlight() -> Flashlight:
	return _flashlight


func die(_attacker_position: Vector3 = Vector3.INF) -> void:
	if _dead:
		return

	_dead = true
	_set_lock_target(null)
	add_to_group("dead")
	velocity = Vector3.ZERO
	died.emit()

	await get_tree().create_timer(respawn_delay).timeout
	_respawn()


func _respawn() -> void:
	if not _dead:
		return

	_dead = false
	remove_from_group("dead")
	global_transform = _spawn_transform
	velocity = Vector3.ZERO

	if not is_instance_valid(_flashlight):
		return

	if not _flashlight.is_held():
		_flashlight.reparent(_flashlight_socket, true)

	_flashlight.transform = Transform3D.IDENTITY
	_flashlight.set_held(true)
	_flashlight.set_light_on(true)
