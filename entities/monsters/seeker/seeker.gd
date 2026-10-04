class_name Seeker
extends CharacterBody3D
## The Seeker - attracted to light sources, attacks them, and smashes through
## obstacle cubes and stalkers that get in its way.
##
## It never targets the player. If the source it attacks is held, the holder
## dies as a consequence.
##
## Expected scene structure (see seeker.tscn):
##   Seeker (CharacterBody3D)
##   ├── Collision   (CollisionShape3D)
##   ├── Navigation  (NavigationAgent3D)
##   ├── Model       (Node3D)
##   │   └── Body    (Mannequin)
##   └── Area        (Area3D, slightly bigger than the body: contact detection)
##
## Light source contract (duck-typed, see TestSubject):
##   - node is in group "light_source"
##   - is_light_on() -> bool
##   - is_held() -> bool
##   - optional destroy()

signal attacked_source(source: Node3D)
signal killed_holder(source: Node3D)
signal killed_monster(monster: Node3D)
signal destroyed_obstacle(obstacle: Node3D)

enum State { IDLE, APPROACH, SEARCH, RETURN, DONE }

@export_group("Tether")
## Optional marker the Seeker returns to. Empty = where it stood at _ready()
## (or where place_at() put it).
@export var tether: NodePath

@export_group("Light")
## Lights further away than this (meters) are ignored.
@export var attraction_radius := 16.0
## If true, walls between the Seeker and a light hide that light from it.
## Obstacle cubes and stalkers never block the view, since the Seeker can
## get through them.
@export var require_line_of_sight := true
## Collision layers that block sight (room geometry).
@export_flags_3d_physics var occluder_mask := 1
## How often (seconds) to look for lights while not chasing one.
@export var light_check_interval := 0.25

@export_group("Movement")
@export var approach_speed := 3.0
@export var return_speed := 2.0
@export var gravity := 25.0
## Distance (meters, on the floor plane) at which it attacks a light source.
@export var reach_distance := 1.0
## How long it stands still after losing the light (seconds).
@export var search_time := 3.0
## How close to the tether counts as "home" (meters).
@export var tether_tolerance := 0.5
## How often the path is refreshed (seconds).
@export var repath_interval := 0.25
## Higher = snappier turning.
@export var turn_speed := 10.0
## The model's forward axis at zero rotation (local XZ), used for aiming.
@export var model_forward := Vector3(0, 0, 1)

@export_group("Strength")
## Group of things it destroys on contact (obstacle cubes).
@export var obstacle_group: StringName = &"obstacle"
## Group of monsters it kills on contact (the Stalker).
@export var prey_group: StringName = &"stalker"
## The navmesh routes around obstacle cubes. With this on, when a cube or
## prey is the first thing between the Seeker and its destination it walks
## straight at it instead, and smashes it.
@export var plow_through_obstacles := true
## Only look this far ahead for things to plow through (meters).
@export var plow_probe_distance := 8.0

@export_group("Debug")
@export var show_debug_label := false

var active := false

var _state: State = State.IDLE
var _state_time := 0.0
var _tether_position := Vector3.ZERO
var _target: Node3D = null
var _light_timer := 0.0
var _repath_timer := 0.0
var _since_repath := 0.0
var _plowing := false
var _handled_ids := {}
## A light the navmesh cannot get it to. It is ignored until that light is
## switched off or moves, so the Seeker goes home instead of flipping between
## approaching and searching.
var _ignored_light: Node3D = null
var _ignored_pos := Vector3.ZERO
var _navigation: NavigationAgent3D
var _model: Node3D
var _area: Area3D
var _debug_label: Label3D

## A fresh path needs a moment before "navigation finished" means anything.
const PATH_SETTLE_TIME := 0.2
## Within this distance of the tether (meters) the Seeker walks straight home.
const HOME_STRETCH := 1.5
## An unreachable light that moves further than this (meters) is worth another try.
const IGNORE_MOVE_DISTANCE := 1.5


func _ready() -> void:
	_navigation = $Navigation
	_model = $Model
	_area = $Area
	_tether_position = global_position
	if not tether.is_empty():
		var marker := get_node_or_null(tether) as Node3D
		if marker:
			_tether_position = marker.global_position
	if show_debug_label:
		_build_debug_label()
		_update_debug_label()


func _physics_process(delta: float) -> void:
	_state_time += delta
	if not active:
		_stand_still(delta)
		return
	_check_contacts()
	match _state:
		State.IDLE:
			_update_idle(delta)
		State.APPROACH:
			_update_approach(delta)
		State.SEARCH:
			_update_search(delta)
		State.RETURN:
			_update_return(delta)
		State.DONE:
			_stand_still(delta)


# ------------------------------------------------------------- activation

## Start looking for lights.
func activate() -> void:
	active = true
	_enter(State.IDLE)


## Stop completely (the owner usually frees the Seeker instead).
func deactivate() -> void:
	active = false
	_target = null
	velocity = Vector3.ZERO
	_enter(State.IDLE)


## Put the Seeker down at a spot and make it its tether (home).
func place_at(pos: Vector3) -> void:
	global_position = pos
	_tether_position = pos
	velocity = Vector3.ZERO


func state_name() -> String:
	if not active:
		return "WAITING (press T)"
	return State.keys()[_state]


# ------------------------------------------------------------------ states

func _update_idle(delta: float) -> void:
	_stand_still(delta)
	if _light_check_due(delta):
		var light := _find_valid_light()
		if light:
			_target = light
			_enter(State.APPROACH)


func _update_approach(delta: float) -> void:
	# A light that was switched off, freed or taken away is lost immediately.
	if not _light_is_on(_target):
		_enter(State.SEARCH)
		return
	if _light_check_due(delta):
		var best := _find_valid_light()
		if best == null:
			_enter(State.SEARCH)
			return
		if best != _target:
			_target = best
			_repath_timer = repath_interval
	var target_pos := _target.global_position
	if _flat_distance(target_pos) <= reach_distance:
		_attack_source(_target)
		return
	_refresh_path(delta, target_pos)
	# The closest reachable point is as far as the navmesh goes.
	if _path_exhausted() and not _plowing:
		_ignored_light = _target
		_ignored_pos = _target.global_position
		_target = null
		_enter(State.SEARCH)
		return
	_move_toward(target_pos, approach_speed, delta)


func _update_search(delta: float) -> void:
	_stand_still(delta)
	if _light_check_due(delta):
		var light := _find_valid_light()
		if light:
			_target = light
			_enter(State.APPROACH)
			return
	if _state_time >= search_time:
		_enter(State.RETURN)


func _update_return(delta: float) -> void:
	if _light_check_due(delta):
		var light := _find_valid_light()
		if light:
			_target = light
			_enter(State.APPROACH)
			return
	if _flat_distance(_tether_position) <= tether_tolerance:
		_enter(State.IDLE)
		return
	if _flat_distance(_tether_position) <= HOME_STRETCH:
		# The navigation agent stops a little short of its target, so the last
		# stretch home is walked straight.
		_move_toward(_tether_position, return_speed, delta, true)
		return
	_refresh_path(delta, _tether_position)
	if _path_exhausted() and not _plowing:
		# Home is unreachable from here: stay put rather than jitter.
		_enter(State.IDLE)
		return
	_move_toward(_tether_position, return_speed, delta)


func _enter(new_state: State) -> void:
	_state = new_state
	_state_time = 0.0
	_light_timer = 0.0
	_plowing = false
	_since_repath = 0.0
	_repath_timer = repath_interval  # repath on the first moving frame
	_update_debug_label()


# ------------------------------------------------------------------ attack

## Reaching a light source attacks the source. A held source means the holder
## dies. The player is never chased for its own sake.
func _attack_source(source: Node3D) -> void:
	attacked_source.emit(source)
	var held: bool = source.has_method("is_held") and source.is_held()
	if held:
		var holder := _find_holder(source)
		if holder and holder.has_method("die"):
			holder.die()
		killed_holder.emit(source)
		_enter(State.DONE)
		return
	# TODO: placed light is destroyed (placing does not exist yet).
	if source.has_method("destroy"):
		source.destroy()
	_target = null
	_enter(State.SEARCH)


func _find_holder(source: Node) -> Node:
	var node := source
	while node:
		if node.is_in_group(&"player"):
			return node
		node = node.get_parent()
	return null


# --------------------------------------------------------------- contacts

## Anything it touches that it is strong enough to remove goes away.
func _check_contacts() -> void:
	if _state == State.DONE:
		return
	for body in _area.get_overlapping_bodies():
		if body == self or _handled_ids.has(body.get_instance_id()):
			continue
		if body.is_in_group(obstacle_group):
			_smash_obstacle(body)
		elif body.is_in_group(prey_group):
			_kill_monster(body)


func _smash_obstacle(obstacle: Node) -> void:
	_handled_ids[obstacle.get_instance_id()] = true
	if obstacle.has_method("destroy"):
		obstacle.destroy()
	else:
		# Out of the tree right away, so a navmesh rebake no longer sees it.
		var parent := obstacle.get_parent()
		if parent:
			parent.remove_child(obstacle)
		obstacle.queue_free()
	destroyed_obstacle.emit(obstacle)


## Calls die() if the monster has one. Otherwise the owner reacts to the
## killed_monster signal (the test room hides and disables the Stalker).
func _kill_monster(monster: Node) -> void:
	_handled_ids[monster.get_instance_id()] = true
	if monster.has_method("die"):
		monster.die()
	killed_monster.emit(monster)


# ----------------------------------------------------------------- lights

func _light_check_due(delta: float) -> bool:
	_light_timer += delta
	if _light_timer < light_check_interval:
		return false
	_light_timer = 0.0
	return true


func _light_is_on(source: Node3D) -> bool:
	return is_instance_valid(source) and source.is_inside_tree() \
		and source.has_method("is_light_on") and source.is_light_on()


## Nearest light that is on, in range and (optionally) in view. Held or placed
## makes no difference.
func _find_valid_light() -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for node in get_tree().get_nodes_in_group(&"light_source"):
		var source := node as Node3D
		if source == null:
			continue
		var on := _light_is_on(source)
		if source == _ignored_light and (not on or source.global_position.distance_to(_ignored_pos) > IGNORE_MOVE_DISTANCE):
			_ignored_light = null
		if not on or source == _ignored_light:
			continue
		var dist := global_position.distance_to(source.global_position)
		if dist > attraction_radius or dist >= best_dist:
			continue
		if require_line_of_sight and not _has_line_of_sight(source):
			continue
		best = source
		best_dist = dist
	return best


func _has_line_of_sight(source: Node3D) -> bool:
	var from := global_position + Vector3.UP * 0.9
	var to := source.global_position + Vector3.UP * 0.9
	var exclude := _body_rids_of(source)
	exclude.append(get_rid())
	var space := get_world_3d().direct_space_state
	# Things the Seeker can smash do not hide a light; keep looking past them.
	for i in 8:
		var query := PhysicsRayQueryParameters3D.create(from, to, occluder_mask)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return true
		var collider := hit.collider as Node
		if collider and _is_smashable(collider):
			exclude.append(hit.rid)
			continue
		return false
	return false


func _is_smashable(node: Node) -> bool:
	return node.is_in_group(obstacle_group) or node.is_in_group(prey_group)


## RIDs of the node and every physics body above it (a light carried by a
## body must not be hidden by that body).
func _body_rids_of(node: Node) -> Array[RID]:
	var rids: Array[RID] = []
	var current := node
	while current:
		if current is CollisionObject3D:
			rids.append((current as CollisionObject3D).get_rid())
		current = current.get_parent()
	return rids


# --------------------------------------------------------------- movement

func _refresh_path(delta: float, target_pos: Vector3) -> void:
	_since_repath += delta
	_repath_timer += delta
	if _repath_timer < repath_interval:
		return
	_repath_timer = 0.0
	_since_repath = 0.0
	_navigation.target_position = target_pos
	_plowing = plow_through_obstacles and _smashable_in_the_way(target_pos)


func _path_exhausted() -> bool:
	return _since_repath >= PATH_SETTLE_TIME and _navigation.is_navigation_finished()


## Is the first thing between the Seeker and the destination something it can
## smash through?
func _smashable_in_the_way(target_pos: Vector3) -> bool:
	var from := global_position + Vector3.UP * 0.9
	var to := Vector3(target_pos.x, from.y, target_pos.z)
	var offset := to - from
	if offset.length() < 0.01:
		return false
	to = from + offset.normalized() * minf(offset.length(), plow_probe_distance)
	var exclude: Array[RID] = []
	exclude.append(get_rid())
	if is_instance_valid(_target):
		exclude.append_array(_body_rids_of(_target))
	var query := PhysicsRayQueryParameters3D.create(from, to, occluder_mask)
	query.exclude = exclude
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var collider := hit.collider as Node
	return collider != null and _is_smashable(collider)


func _steer_direction(target_pos: Vector3, force_straight := false) -> Vector3:
	var straight := target_pos - global_position
	straight.y = 0.0
	straight = straight.normalized()
	if force_straight or _plowing:
		return straight
	var to_next := _navigation.get_next_path_position() - global_position
	to_next.y = 0.0
	if to_next.length() > 0.05:
		return to_next.normalized()
	return Vector3.ZERO


func _move_toward(target_pos: Vector3, speed: float, delta: float, force_straight := false) -> void:
	var direction := _steer_direction(target_pos, force_straight)
	if direction == Vector3.ZERO:
		_stand_still(delta)
		return
	_face(direction, delta)
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	_apply_gravity(delta)
	move_and_slide()


func _stand_still(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_apply_gravity(delta)
	move_and_slide()


func _apply_gravity(delta: float) -> void:
	velocity.y = 0.0 if is_on_floor() else velocity.y - gravity * delta


func _flat_distance(point: Vector3) -> float:
	return Vector2(point.x - global_position.x, point.z - global_position.z).length()


func _face(direction: Vector3, delta: float) -> void:
	var target_yaw := _yaw_to(direction)
	_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))


## Yaw rotation that makes `model_forward` point at `direction`.
func _yaw_to(direction: Vector3) -> float:
	var d := direction
	d.y = 0.0
	var forward := model_forward
	forward.y = 0.0
	if d.length() < 0.001 or forward.length() < 0.001:
		return _model.rotation.y
	d = d.normalized()
	forward = forward.normalized()
	return -atan2(d.cross(forward).y, d.dot(forward))


# ------------------------------------------------------------------ debug

func _build_debug_label() -> void:
	_debug_label = Label3D.new()
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.008
	_debug_label.font_size = 48
	_debug_label.position = Vector3(0, 2.3, 0)
	add_child(_debug_label)


func _update_debug_label() -> void:
	if _debug_label:
		_debug_label.text = state_name()
