class_name Flashlight
extends Node3D
## Physical flashlight.
##
## ONE light source: the SpotLight3D "TorchLight", which sits at the lens.
## Its angle, range, energy and rotation are set on that node in the editor.
## This script never changes them: it only reads them, so the cone that lights
## the floor is the same cone used to decide whether a Stalker is lit.
##
## This works while the flashlight is held or dropped because detection is
## based on the flashlight's world transform, not the Player.

@export_group("Dropped")
## Height of the torch (and its lens) above the floor when it is dropped.
@export var dropped_height := 0.08

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


func _ready() -> void:
	add_to_group("light_source")

	_apply_light_state()


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


func set_light_on(value: bool) -> void:
	if _is_on == value:
		return

	_is_on = value
	_apply_light_state()
	_update_stalker_illumination()


func toggle() -> void:
	set_light_on(not _is_on)


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
	var forward: Vector3 = -_light.global_transform.basis.z
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
