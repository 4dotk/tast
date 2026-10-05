class_name Flashlight
extends Node3D
## Physical flashlight.
##
## ONE light source: the SpotLight3D "TorchLight", which sits at the lens.
## Its angle, range and energy are set on that node in the editor and never
## changed here, so the cone that lights the floor is the same cone used to
## decide whether a Stalker is lit.
##
## The torch MODEL always stays on the hand bone. Only the beam's transform is
## driven (see _update_beam):
##   - dropped / idle / picking up: the beam follows the torch.
##   - held and moving: the beam is fixed to the Player's body, so the arm swing
##     of the run cycle does not make it sweep back and forth.
## Detection reads the beam's real transform, so lock-on sees what you see.

@export_group("Dropped")
## Height of the torch (and its lens) above the floor when it is dropped.
@export var dropped_height := 0.08

@export_group("Beam")
## While held, the beam is tilted down by this much on top of the TorchLight's
## own rotation, so the lit patch starts nearer the player. Not applied when
## dropped. For a torch ~1.8 m up and a 30 degree cone, the near edge of the
## patch reaches the floor at about 1.8 / tan(pitch + 30): 0 -> 3.1 m,
## 15 -> 1.8 m, 28 -> 1.1 m, 35 -> 0.8 m. Past ~36 the top of the cone points
## below horizontal and the beam stops reaching its full range.
@export_range(0.0, 60.0) var held_beam_pitch_degrees := 28.0
## Only while the beam is fixed to the body (running): the beam origin is
## nudged by this much in the beam's own space (X right, Y up, -Z forward) so
## the swinging left hand does not sit in front of the light and shadow it.
## Keep it small; it moves the origin, not the direction.
@export var running_beam_offset := Vector3(0.0, 0.05, -0.2)
## Seconds to blend between "beam follows the torch" and "beam fixed to body".
@export_range(0.01, 1.0) var beam_blend_time := 0.2

@export_group("Stalker Detection")
@export var check_interval := 0.05
@export var require_line_of_sight := true
@export_flags_3d_physics var occluder_mask := 1

# Several points let a dropped flashlight hit the lower body while a held
# flashlight can hit the chest/head area.
@export var target_sample_heights := PackedFloat32Array([0.2, 0.6, 1.0, 1.4])

## The visible falloff at the cone's edge is dim, so only count the inner part
## of the cone as "lit" for the Stalker.
const EDGE_MARGIN := 0.9

@onready var _light: SpotLight3D = $TorchLight

var _is_on := true
var _held := true
var _check_timer := 0.0

## TorchLight's pose relative to the torch, as authored in flashlight.tscn.
var _light_rest := Transform3D.IDENTITY
## Body the running beam is fixed to (the Player).
var _beam_reference: Node3D
var _beam_fixed := false
## 0 = beam follows the torch, 1 = beam fixed to the reference body.
var _fixed_weight := 0.0
## Beam pose in the reference body's space, captured when it becomes fixed.
var _fixed_local := Transform3D.IDENTITY
## 0 = dropped (no tilt), 1 = held (full tilt).
var _held_weight := 1.0


func _ready() -> void:
	add_to_group("light_source")

	if is_instance_valid(_light):
		# Authored pose of the beam relative to the torch.
		_light_rest = _light.transform
		# The beam is placed in global space by _update_beam(). Set at runtime
		# only, so the editor still shows the beam attached to the torch.
		_light.top_level = true
		_light.global_transform = _follow_pose()

	_apply_light_state()


func _process(delta: float) -> void:
	_update_beam(delta)


func _physics_process(delta: float) -> void:
	_check_timer -= delta
	if _check_timer > 0.0:
		return

	_check_timer = check_interval
	_update_stalker_illumination()


func is_light_on() -> bool:
	return _is_on


func is_held() -> bool:
	return _held


func set_held(value: bool) -> void:
	_held = value


## The body the beam is fixed to while running (the Player).
func set_beam_reference(reference: Node3D) -> void:
	_beam_reference = reference


## true: the beam is fixed to the reference body (running).
## false: the beam follows the torch (idle, dropped, picking up).
func set_beam_fixed(value: bool) -> void:
	_beam_fixed = value


func set_light_on(value: bool) -> void:
	if _is_on == value:
		return

	_is_on = value
	_apply_light_state()
	_update_stalker_illumination()


func toggle() -> void:
	set_light_on(not _is_on)


## Where the beam sits when it simply follows the torch.
func _follow_pose() -> Transform3D:
	var tilt := deg_to_rad(held_beam_pitch_degrees) * smoothstep(0.0, 1.0, _held_weight)
	# A negative rotation about the light's own X axis tilts its beam (-Z) down.
	var aim := Transform3D(Basis(Vector3.RIGHT, -tilt), Vector3.ZERO)
	return (global_transform * _light_rest * aim).orthonormalized()


func _update_beam(delta: float) -> void:
	if not is_instance_valid(_light):
		return

	var step := delta / beam_blend_time
	_held_weight = move_toward(_held_weight, 1.0 if _held else 0.0, step)
	var follow := _follow_pose()

	var want_fixed := _beam_fixed and _held and is_instance_valid(_beam_reference)

	# Freeze the beam in the body's space at the moment it stops following the
	# torch, so there is no pop and it keeps the pose it had while idle.
	if want_fixed and is_zero_approx(_fixed_weight):
		var nudged := follow * Transform3D(Basis.IDENTITY, running_beam_offset)
		_fixed_local = _beam_reference.global_transform.affine_inverse() * nudged
	_fixed_weight = move_toward(_fixed_weight, 1.0 if want_fixed else 0.0, step)

	if _fixed_weight > 0.0 and is_instance_valid(_beam_reference):
		var fixed := (_beam_reference.global_transform * _fixed_local).orthonormalized()
		_light.global_transform = follow.interpolate_with(
			fixed, smoothstep(0.0, 1.0, _fixed_weight)
		)
	else:
		_light.global_transform = follow


func _apply_light_state() -> void:
	if not is_instance_valid(_light):
		return

	_light.visible = _is_on


func _update_stalker_illumination() -> void:
	for node in get_tree().get_nodes_in_group("stalker"):
		if not node is Node3D:
			continue
		if not node.has_method("set_lit"):
			continue

		var stalker := node as Node3D
		var lit := _is_on and _is_stalker_in_beam(stalker)
		stalker.set_lit(lit)


func _is_stalker_in_beam(stalker: Node3D) -> bool:
	if not _is_on or not is_instance_valid(_light):
		return false

	var origin: Vector3 = _light.global_position
	var forward: Vector3 = -_light.global_transform.basis.z.normalized()
	var max_distance := _light.spot_range
	var min_dot := cos(deg_to_rad(_light.spot_angle * EDGE_MARGIN))

	for height in target_sample_heights:
		var target_point: Vector3 = stalker.global_position + Vector3.UP * height
		var offset: Vector3 = target_point - origin
		var distance: float = offset.length()

		if distance < 0.001 or distance > max_distance:
			continue

		var direction: Vector3 = offset / distance
		if direction.dot(forward) < min_dot:
			continue

		if not require_line_of_sight:
			return true

		if _has_line_of_sight(origin, target_point, stalker):
			return true

	return false


func _has_line_of_sight(
	origin: Vector3,
	target_point: Vector3,
	stalker: Node3D
) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		origin,
		target_point,
		occluder_mask
	)
	query.collide_with_bodies = true
	query.collide_with_areas = true
	query.exclude = _get_source_exclusions()

	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true

	var collider := hit.get("collider") as Node
	return _is_part_of_stalker(collider, stalker)


func _get_source_exclusions() -> Array[RID]:
	var exclusions: Array[RID] = []
	var current: Node = self

	while current != null:
		if current is CollisionObject3D:
			exclusions.append((current as CollisionObject3D).get_rid())
		current = current.get_parent()

	return exclusions


func _is_part_of_stalker(node: Node, stalker: Node3D) -> bool:
	var current := node

	while current != null:
		if current == stalker:
			return true
		current = current.get_parent()

	return false
