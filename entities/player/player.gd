extends CharacterBody3D
##
## Silent Hill 3-style controls (camera-agnostic: works with any camera setup).
##   W / S : move forward / back away (S backs up WITHOUT turning the player)
##   A / D : turn left / turn right   (become strafe left / right while locked on)
##   Q     : toggle lock-on. No enemy in range -> the torch just points forward.
##           Enemy in range -> the player turns to face the closest one.
##   E     : priority 1) interact with objects (doors)
##           priority 2) pick up / drop the torch
##   F     : flashlight on / off

const MOVE_SPEED := 4.0          # m/s
const TURN_SPEED := 2.5          # rad/s, turning while not locked on
const LOCK_TURN_SPEED := 4.0     # rad/s, turning to face the locked-on enemy
const ENEMY_RANGE := 9.0         # m
const ENEMY_CONE_DEG := 70.0     # enemies must be roughly in front to be targetable
const INTERACT_RANGE := 1.8      # m
const INTERACT_FACING := 0.3     # how "in front" an interactable must be (dot product)
const PICKUP_RANGE := 2.0        # m
const HAND_POSITION := Vector3(0.5, 0.12, -0.5)
const DROP_DISTANCE := 0.7       # m in front of the player when dropping the torch
const FLASHLIGHT_ENERGY := 4.0   # must match TorchLight.light_energy in player.tscn

@onready var _torch: Node3D = $Torch
@onready var _torch_light: SpotLight3D = $Torch/TorchLight

var _holding_torch := true
var _locked_on := false
var _light_is_on := true


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	if not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_Q:
			_locked_on = not _locked_on
		KEY_F:
			_light_is_on = not _light_is_on
			_apply_light_state()
		KEY_E:
			_try_interact()


func _physics_process(delta: float) -> void:
	var forward := -transform.basis.z
	var right := transform.basis.x

	# A / D: turn while free, strafe while locked on.
	var turn_input := 0.0
	if Input.is_key_pressed(KEY_A):
		turn_input += 1.0
	if Input.is_key_pressed(KEY_D):
		turn_input -= 1.0
	var strafe_input := 0.0
	if _locked_on:
		strafe_input = -turn_input
	else:
		rotate_y(turn_input * TURN_SPEED * delta)

	# W / S: forward / back. S never rotates the player.
	var move_input := 0.0
	if Input.is_key_pressed(KEY_W):
		move_input += 1.0
	if Input.is_key_pressed(KEY_S):
		move_input -= 1.0

	var direction := forward * move_input + right * strafe_input
	if direction.length_squared() > 1.0:
		direction = direction.normalized()
	velocity = direction * MOVE_SPEED
	move_and_slide()

	# Lock-on: keep facing the closest enemy in front.
	# With no enemy in range nothing happens and the torch points forward.
	if _locked_on:
		_face_lock_target(delta)


## Toggles the flashlight. Recent Godot 4.x removed Light3D.enabled,
## so on/off is done by zeroing / restoring light_energy instead.
func _apply_light_state() -> void:
	_torch_light.light_energy = FLASHLIGHT_ENERGY if _light_is_on else 0.0


## Turns toward the closest enemy in the "enemies" group.
func _face_lock_target(delta: float) -> void:
	var target := _closest_in_front("enemies", ENEMY_RANGE, cos(deg_to_rad(ENEMY_CONE_DEG)))
	if target == null:
		return
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.001:
		return
	to_target = to_target.normalized()
	var forward := -transform.basis.z
	var angle := forward.angle_to(to_target)
	if angle < 0.005:
		return
	# Positive cross.y means the target is to the left.
	var side := forward.cross(to_target).y
	var step := minf(LOCK_TURN_SPEED * delta, angle)
	rotate_y(step if side > 0.0 else -step)


## Returns the closest node in [group] that is within [max_dist] m and at
## least [min_facing] of the forward direction (dot product).
func _closest_in_front(group: String, max_dist: float, min_facing: float) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	var forward := -transform.basis.z
	for node in get_tree().get_nodes_in_group(group):
		if not node is Node3D:
			continue
		var to_node: Vector3 = node.global_position - global_position
		var dist := to_node.length()
		if dist < 0.001 or dist > max_dist:
			continue
		if to_node.normalized().dot(forward) < min_facing:
			continue
		if dist < best_dist:
			best_dist = dist
			best = node
	return best


## E key: 1) interact with objects (doors)  2) pick up / drop the torch.
func _try_interact() -> void:
	var target := _closest_in_front("interactables", INTERACT_RANGE, INTERACT_FACING)
	if target != null:
		if target.has_method("interact"):
			target.interact(self)
		return
	# Priority 2: the torch.
	if _holding_torch:
		_drop_torch()
	else:
		var to_torch: Vector3 = _torch.global_position - global_position
		if to_torch.length() <= PICKUP_RANGE:
			_pick_up_torch()


func _drop_torch() -> void:
	_torch.set_as_parent(get_parent(), true)
	_torch.global_position = global_position + (-transform.basis.z) * DROP_DISTANCE
	_torch.global_position.y = 0.05
	_holding_torch = false


func _pick_up_torch() -> void:
	_torch.set_as_parent(self, true)
	_torch.position = HAND_POSITION
	_torch.rotation = Vector3.ZERO
	_holding_torch = true
