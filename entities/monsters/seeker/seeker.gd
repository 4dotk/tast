class_name Seeker
extends CharacterBody3D
## The Seeker - a slow brute attracted to light sources. It attacks them, and
## when an obstacle cube or a stalker is in its way it stops, attacks that,
## then carries on.
##
## The Seeker uses the seeker_model.tscn scene (Seeker.glb + the textured
## material override). Its AnimationPlayer is found inside that model and uses
## these animation names:
##   Seeker_Look
##   Seeker_Run
##   Seeker_Attack
##
## The collision box (Area) is its reach. Whenever the player is inside it,
## whether the Seeker walked into the player or the player walked into the
## Seeker, it plays the attack clip and the player dies when the hit lands.
## The hit is skipped if the player has got well away by then.

signal attacked_source(source: Node3D)
signal killed_holder(source: Node3D)
signal killed_monster(monster: Node3D)
signal destroyed_obstacle(obstacle: Node3D)

enum State { IDLE, APPROACH, SEARCH, RETURN, ATTACK, DONE }
## What the current ATTACK is aimed at.
enum AttackKind { SOURCE, BLOCKER, PLAYER }

@export_group("Tether")
@export var tether: NodePath

@export_group("Light")
@export var attraction_radius := 16.0
@export var require_line_of_sight := true
@export_flags_3d_physics var occluder_mask := 1
@export var light_check_interval := 0.25
## When the light being chased goes off, keep heading to where it was for
## this long (seconds) before giving up and searching.
@export var light_off_delay := 0.5

@export_group("Movement")
## Slower than the Stalker on purpose (brute).
@export var approach_speed := 3.5
@export var return_speed := 2.6
@export var gravity := 25.0
@export var reach_distance := 1.0
@export var holder_reach_distance := 1.4
@export var search_time := 3.0
@export var tether_tolerance := 0.5
@export var repath_interval := 0.25
@export var turn_speed := 10.0
@export var model_forward := Vector3(0, 0, 1)

@export_group("Strength")
@export var obstacle_group: StringName = &"obstacle"
@export var prey_group: StringName = &"stalker"
@export var plow_through_obstacles := true
@export var plow_probe_distance := 8.0

@export_group("Attack")
## While heading for a target through an obstacle or monster, the Seeker stops
## and attacks it once it is this close (meters, measured from the Seeker's
## centre).
@export var obstacle_attack_distance := 1.3
## When the hit lands, as a fraction of the attack clip: set it to the frame
## where the claw connects. 0 = the instant the attack starts, 1 = the end.
## The rest of the clip plays as follow-through.
@export_range(0.0, 1.0) var attack_hit_fraction := 0.5
## A hit only lands if its target is still within reach plus this many meters
## when it lands: brushing past still gets hit, running away dodges it.
@export var attack_hit_slack := 1.0
## Group of the player body that triggers an attack when it is in the box.
@export var player_group: StringName = &"player"

@export_group("Animation")
@export var look_animation: StringName = &"Seeker_Look"
@export var run_animation: StringName = &"Seeker_Run"
@export var attack_animation: StringName = &"Seeker_Attack"
## Cross-fade between clips (seconds) so they do not snap.
@export var blend_time := 0.15
## Playback speed of each clip. The look clip is played faster while the
## Seeker is SEARCHING than while it is idling.
@export var idle_look_speed := 1.0
@export var search_look_speed := 1.8
@export var run_speed_scale := 0.5
@export var attack_speed_scale := 1.0
## Short cross-fade into the attack so the swing is not eaten by a long blend.
@export var attack_blend_time := 0.05
## The run clip moves the model forward and snaps it back every loop. Since
## the body is moved by the CharacterBody3D, flatten that horizontal travel on
## the root tracks so the model stays in place and only the legs animate.
@export var strip_root_motion := true
## Root tracks that travel less than this (meters) are left alone.
@export var root_motion_threshold := 0.01
## Match the run clip's playback speed to how fast the Seeker really moves, so
## the feet keep up with the ground. The clip's natural speed is measured from
## the root motion that was removed; if none is found, run_reference_speed
## (m/s the clip looks right at) is used instead.
@export var sync_run_to_movement := true
@export var run_reference_speed := 3.0
## Print which clip is chosen whenever the animation changes.
@export var debug_animations := true

var active := false

var _state: State = State.IDLE
var _state_time := 0.0
var _tether_position := Vector3.ZERO
var _target: Node3D = null
var _attack_target: Node3D = null
var _light_timer := 0.0
var _repath_timer := 0.0
var _since_repath := 0.0
var _plowing := false
var _handled_ids := {}
var _ignored_light: Node3D = null
var _ignored_pos := Vector3.ZERO
var _navigation: NavigationAgent3D
var _model: Node3D
var _area: Area3D
var _animation_player: AnimationPlayer
var _resolved_clips := {}
## True on frames where the Seeker is actually trying to walk somewhere.
var _moving := false
var _attack_duration := 0.0
var _attack_kind: AttackKind = AttackKind.SOURCE
## State to go back to after attacking something that blocked the way.
var _resume_state: State = State.IDLE
var _attack_hit_done := false
var _attack_missed := false
var _holder_killed := false
var _light_off_time := 0.0
var _move_speed := 3.0
## clip name -> meters of forward travel per loop that was removed.
var _clip_travel := {}
## Animation resource id -> removed travel (the clips are shared between Seekers).
static var _stripped := {}
var _last_target_pos := Vector3.ZERO

const PATH_SETTLE_TIME := 0.2
const HOME_STRETCH := 1.5
const IGNORE_MOVE_DISTANCE := 1.5


func _ready() -> void:
	add_to_group("enemies")
	_navigation = $Navigation
	_model = $Model
	_area = $Area
	_animation_player = _find_animation_player(_model)
	if strip_root_motion:
		_strip_root_motion()
	_print_clips()
	_tether_position = global_position

	if not tether.is_empty():
		var marker := get_node_or_null(tether) as Node3D
		if marker:
			_tether_position = marker.global_position

	_play_look_animation()


func _physics_process(delta: float) -> void:
	_state_time += delta
	_moving = false

	if not active:
		_stand_still(delta)
		_update_animation()
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
		State.ATTACK:
			_update_attack(delta)
		State.DONE:
			_stand_still(delta)

	_update_animation()


# ------------------------------------------------------------- activation

func activate() -> void:
	active = true
	_enter(State.IDLE)


func deactivate() -> void:
	active = false
	_target = null
	_attack_target = null
	_ignored_light = null
	_handled_ids.clear()
	velocity = Vector3.ZERO
	if _animation_player != null:
		_animation_player.stop()
	_enter(State.IDLE)


## Human readable state, used by the test room's debug label.
func state_name() -> String:
	if not active:
		return "INACTIVE"
	return String(State.keys()[_state])


func place_at(pos: Vector3) -> void:
	global_position = pos
	_tether_position = pos
	velocity = Vector3.ZERO


# ------------------------------------------------------------------ states

func _update_idle(delta: float) -> void:
	_stand_still(delta)
	if _light_check_due(delta):
		var light := _find_valid_light()
		if light:
			_target = light
			_enter(State.APPROACH)


func _update_approach(delta: float) -> void:
	if _light_is_on(_target):
		_light_off_time = 0.0
		_last_target_pos = _target.global_position
	else:
		# The light went off: keep heading to where it was for a moment
		# before giving up.
		_light_off_time += delta
		if _light_off_time >= light_off_delay:
			_enter(State.SEARCH)
			return
		_refresh_path(delta, _last_target_pos)
		_move_toward(_last_target_pos, approach_speed, delta)
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
	if _in_reach_of(_target):
		_attack_source(_target)
		return

	_refresh_path(delta, target_pos)
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
		_move_toward(_tether_position, return_speed, delta, true)
		return

	_refresh_path(delta, _tether_position)
	if _path_exhausted() and not _plowing:
		_enter(State.IDLE)
		return

	_move_toward(_tether_position, return_speed, delta)


func _update_attack(delta: float) -> void:
	_stand_still(delta)

	if is_instance_valid(_attack_target):
		var to_target := _attack_target.global_position - global_position
		to_target.y = 0.0
		if to_target.length() > 0.05:
			_face(to_target.normalized(), delta)

	_try_attack_hit()

	# The attack clip is started once in _enter() and is never restarted or
	# replaced while it plays. The hit has already landed by now (see
	# attack_hit_fraction); this only waits for the follow-through to finish.
	if _state_time >= maxf(_attack_duration, 0.1):
		_end_attack()


func _enter(new_state: State) -> void:
	_state = new_state
	_state_time = 0.0
	_light_timer = 0.0
	_light_off_time = 0.0
	_plowing = false
	_since_repath = 0.0
	_repath_timer = repath_interval

	# Look / run clips are chosen every frame by _update_animation(); only the
	# one-shot attack clip is started here.
	if new_state == State.ATTACK:
		_attack_hit_done = false
		_attack_missed = false
		_holder_killed = false
		_attack_duration = _play_attack_animation()


# ---------------------------------------------------------------- animation

func _find_animation_player(from_node: Node) -> AnimationPlayer:
	if from_node == null:
		return null
	var players: Array[Node] = from_node.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		return players[0] as AnimationPlayer
	return null


## Flattens the horizontal travel of every position track in every clip,
## measured in the Model's space (not the skeleton's), so the model no longer
## slides forward and snaps back each loop. The Seeker.glb root (Mixamo Hips)
## travels along the skeleton's Y axis, which becomes Model Z after the
## Armature's 90-degree rotation. Vertical bob is kept.
## The removed travel (in meters per loop) is remembered per clip for speed sync.
func _strip_root_motion() -> void:
	if _animation_player == null:
		return
	var root := _animation_player.get_node_or_null(_animation_player.root_node)
	if root == null:
		return
	var model_inv := _model.global_transform.affine_inverse()
	for clip_name in _animation_player.get_animation_list():
		var anim := _animation_player.get_animation(clip_name)
		var id := anim.get_instance_id()
		if _stripped.has(id):
			_clip_travel[clip_name] = _stripped[id]
			continue
		var clip_travel := 0.0
		for i in anim.get_track_count():
			if anim.track_get_type(i) != Animation.TYPE_POSITION_3D:
				continue
			var keys := anim.track_get_key_count(i)
			if keys < 2:
				continue
			# Track space -> Model space, so "horizontal" really means X/Z.
			var to_model := _track_to_model(root, anim.track_get_path(i), model_inv)
			var to_track := to_model.affine_inverse()
			var first: Vector3 = to_model * anim.track_get_key_value(i, 0)
			var travel := 0.0
			for k in keys:
				var m: Vector3 = to_model * anim.track_get_key_value(i, k)
				travel = maxf(travel, Vector2(m.x - first.x, m.z - first.z).length())
			if travel <= root_motion_threshold:
				continue
			for k in keys:
				var m: Vector3 = to_model * anim.track_get_key_value(i, k)
				anim.track_set_key_value(i, k, to_track * Vector3(first.x, m.y, first.z))
			# The keys span (keys - 1) intervals; add the missing step so this is
			# the true travel per loop. Already in meters.
			travel *= float(keys) / float(keys - 1)
			clip_travel = maxf(clip_travel, travel)
			if debug_animations:
				print("Seeker: removed %.3f m of root motion from '%s' in clip '%s'" % [
					travel, anim.track_get_path(i), clip_name])
		_stripped[id] = clip_travel
		_clip_travel[clip_name] = clip_travel


## Transform that converts a position track's values into the Model's space.
func _track_to_model(root: Node, path: NodePath, model_inv: Transform3D) -> Transform3D:
	var node := root.get_node_or_null(NodePath(path.get_concatenated_names())) as Node3D
	if node == null:
		return Transform3D.IDENTITY
	if node is Skeleton3D and path.get_subname_count() > 0:
		var skel := node as Skeleton3D
		var space := model_inv * skel.global_transform
		var bone := skel.find_bone(String(path.get_subname(0)))
		if bone >= 0 and skel.get_bone_parent(bone) >= 0:
			space = space * skel.get_bone_global_rest(skel.get_bone_parent(bone))
		return space
	if node.get_parent() is Node3D:
		return model_inv * (node.get_parent() as Node3D).global_transform
	return model_inv * node.global_transform


## Picks the clip from what the Seeker is really doing this frame:
##   ATTACK            -> attack clip (started once in _enter, left alone)
##   moving            -> run clip
##   standing, SEARCH  -> look clip, played faster
##   standing, other   -> look clip at normal speed
func _update_animation() -> void:
	if _animation_player == null:
		return
	if active and _state == State.ATTACK:
		return
	if _moving:
		_play_run_animation()
	elif active and _state == State.SEARCH:
		_play_look_animation(true)
	else:
		_play_look_animation(false)


func _play_look_animation(searching := false) -> void:
	_play_animation(look_animation, true, search_look_speed if searching else idle_look_speed)


func _play_run_animation() -> void:
	_play_animation(run_animation, true, _run_playback_speed())


func _run_playback_speed() -> float:
	if not sync_run_to_movement:
		return run_speed_scale
	return clampf(_move_speed / _natural_run_speed(), 0.5, 3.0) * run_speed_scale


## Meters per second the run clip covers on its own.
func _natural_run_speed() -> float:
	var clip := _resolve_animation_name(run_animation)
	var travel: float = _clip_travel.get(clip, 0.0)
	if travel > 0.05 and _animation_player != null:
		var anim := _animation_player.get_animation(clip)
		if anim != null and anim.length > 0.01:
			return travel / anim.length
	return maxf(run_reference_speed, 0.1)


## Returns how long (seconds) the attack clip takes at its playback speed.
## Always starts from the first frame, with a short blend.
func _play_attack_animation() -> float:
	return _play_animation(attack_animation, false, attack_speed_scale, attack_blend_time, true)


## Plays a clip and returns its duration in seconds (0 if it does not exist).
## blend < 0 uses blend_time. restart = start over even if it is already playing.
func _play_animation(
	animation_name: StringName,
	looped: bool,
	speed := 1.0,
	blend := -1.0,
	restart := false
) -> float:
	if _animation_player == null:
		return 0.0

	var resolved_name := _resolve_animation_name(animation_name)
	if resolved_name == StringName():
		return 0.0

	var animation := _animation_player.get_animation(resolved_name)
	var duration := animation.length / maxf(speed, 0.01) if animation else 0.0

	_animation_player.speed_scale = speed
	if _animation_player.current_animation == resolved_name and _animation_player.is_playing():
		if restart:
			_animation_player.seek(0.0, true)
		return duration

	# Set the loop mode BEFORE playing so the clip starts with the right mode.
	if animation:
		animation.loop_mode = Animation.LOOP_LINEAR if looped else Animation.LOOP_NONE
	if debug_animations:
		print("Seeker: %s -> clip '%s' (speed %.2f)" % [animation_name, resolved_name, speed])
	_animation_player.play(resolved_name, blend_time if blend < 0.0 else blend)
	return duration


## Exact name first, then a case-insensitive match that also accepts a
## library / importer prefix (e.g. "Armature|Seeker_Run", "lib/Seeker_Run").
func _find_clip_by_name(requested: StringName) -> StringName:
	if _animation_player.has_animation(requested):
		return requested
	var wanted := String(requested).to_lower()
	for clip in _animation_player.get_animation_list():
		if String(clip).to_lower().ends_with(wanted):
			return clip
	return StringName()


## Turns a requested clip name into a clip that really exists on the player.
## If it is missing, a warning names the clips that do exist so the exported
## names (or the three *_animation exports) can be fixed.
func _resolve_animation_name(requested: StringName) -> StringName:
	if _resolved_clips.has(requested):
		return _resolved_clips[requested]

	var result := _find_clip_by_name(requested)
	if result == StringName():
		push_warning("Seeker: clip '%s' not found. Available: %s" % [
			requested, ", ".join(_animation_player.get_animation_list())])

	_resolved_clips[requested] = result
	return result


func _print_clips() -> void:
	if _animation_player == null:
		push_warning("Seeker: no AnimationPlayer found inside the model.")
		return
	print("Seeker clips available:")
	for clip in _animation_player.get_animation_list():
		var anim := _animation_player.get_animation(clip)
		print("  '%s'  length %.2fs" % [clip, anim.length])
	if sync_run_to_movement:
		print("Seeker: run clip natural speed %.2f m/s, moving at %.2f m/s" % [
			_natural_run_speed(), approach_speed])
	print("Seeker uses: look='%s' run='%s' attack='%s'" % [
		_resolve_animation_name(look_animation),
		_resolve_animation_name(run_animation),
		_resolve_animation_name(attack_animation)])


# ------------------------------------------------------------------ attack

func _attack_source(source: Node3D) -> void:
	if not is_instance_valid(source):
		_enter(State.SEARCH)
		return
	_attack_target = source
	_attack_kind = AttackKind.SOURCE
	_enter(State.ATTACK)
	_try_attack_hit()


## The player is in the collision box: play the attack, and the player dies
## when the hit lands (see attack_hit_fraction).
func _begin_player_attack(player: Node3D) -> void:
	_attack_target = player
	_attack_kind = AttackKind.PLAYER
	_enter(State.ATTACK)
	_try_attack_hit()


## Something that blocks the way (obstacle cube / monster): stop, attack it,
## then go back to whatever the Seeker was doing.
func _begin_blocker_attack(blocker: Node3D) -> void:
	_resume_state = _state
	_attack_target = blocker
	_attack_kind = AttackKind.BLOCKER
	_enter(State.ATTACK)
	_try_attack_hit()


## Lands the hit once the attack clip has reached attack_hit_fraction
## (0 = right away).
func _try_attack_hit() -> void:
	if _attack_hit_done:
		return
	if _state_time < _attack_duration * attack_hit_fraction:
		return
	_attack_hit_done = true
	_apply_attack_hit()


func _apply_attack_hit() -> void:
	var victim := _attack_target
	if not is_instance_valid(victim):
		_attack_missed = true
		return

	match _attack_kind:
		AttackKind.BLOCKER:
			if victim.is_in_group(prey_group):
				_kill_monster(victim)
			else:
				_smash_obstacle(victim)
		AttackKind.PLAYER:
			_hit_player(victim)
		_:
			_hit_source(victim)


## The claw connects: the player dies unless it has got well away.
func _hit_player(player: Node3D) -> void:
	if player.is_in_group(&"dead") \
			or _flat_distance(player.global_position) > holder_reach_distance + attack_hit_slack:
		_attack_missed = true
		return

	var source: Node3D = player
	if player.has_method("get_flashlight"):
		var torch = player.get_flashlight()
		if torch is Node3D:
			source = torch

	attacked_source.emit(source)
	if player.has_method("die"):
		player.die(global_position)
	killed_holder.emit(source)
	_holder_killed = true


## A light that is lying on the ground. (A held light is handled as the player.)
func _hit_source(source: Node3D) -> void:
	if source.has_method("is_held") and source.is_held():
		_attack_missed = true
		return
	if not _in_reach_of(source, attack_hit_slack):
		_attack_missed = true
		return

	attacked_source.emit(source)
	if source.has_method("destroy"):
		source.destroy()


## The attack clip has finished playing: decide what to do next.
func _end_attack() -> void:
	var kind := _attack_kind
	_attack_target = null

	if _holder_killed:
		_enter(State.DONE)
		return

	if kind == AttackKind.BLOCKER:
		_enter(_resume_state)
		return

	# Missed (the target got away): keep going for the same light if there is one.
	if _attack_missed and _light_is_on(_target):
		_enter(State.APPROACH)
		return

	_target = null
	_enter(State.SEARCH)


## Dropped lights only. A held light is "reached" through its holder, which is
## caught by the collision box in _check_contacts().
func _in_reach_of(source: Node3D, extra := 0.0) -> bool:
	if source.has_method("is_held") and source.is_held():
		return false
	return _flat_distance(source.global_position) <= reach_distance + extra


func _find_holder(source: Node) -> Node:
	var node := source
	while node:
		if node.is_in_group(&"player"):
			return node
		node = node.get_parent()
	return null


# --------------------------------------------------------------- contacts

## Whatever enters the Seeker's collision box gets attacked, not deleted on the
## spot. The player comes first and can interrupt an attack on an obstacle.
func _check_contacts() -> void:
	if _state == State.DONE:
		return
	if _state == State.ATTACK and _attack_kind == AttackKind.PLAYER:
		return

	var player := _find_player_in_box()
	if player != null:
		_begin_player_attack(player)
		return

	if _state == State.ATTACK:
		return
	for body in _area.get_overlapping_bodies():
		if body == self or _handled_ids.has(body.get_instance_id()):
			continue
		if body is Node3D and _is_smashable(body):
			_begin_blocker_attack(body as Node3D)
			return


## The player, if it is inside the collision box. The distance check is a
## safety net for the case where the Area does not see the player's layer.
func _find_player_in_box() -> Node3D:
	for node in get_tree().get_nodes_in_group(player_group):
		var player := node as Node3D
		if player == null or player.is_in_group(&"dead"):
			continue
		if player is CollisionObject3D and _area.overlaps_body(player):
			return player
		if _flat_distance(player.global_position) <= holder_reach_distance:
			return player
	return null


func _smash_obstacle(obstacle: Node) -> void:
	_handled_ids[obstacle.get_instance_id()] = true
	if obstacle.has_method("destroy"):
		obstacle.destroy()
	else:
		var parent := obstacle.get_parent()
		if parent:
			parent.remove_child(obstacle)
		obstacle.queue_free()
	destroyed_obstacle.emit(obstacle)


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


## The obstacle / monster directly ahead (within obstacle_attack_distance), or
## null. Uses the same ray rules as _smashable_in_the_way().
func _probe_blocker(direction: Vector3) -> Node3D:
	var from := global_position + Vector3.UP * 0.9
	var to := from + direction * obstacle_attack_distance
	var exclude: Array[RID] = [get_rid()]
	if is_instance_valid(_target):
		exclude.append_array(_body_rids_of(_target))
	var space := get_world_3d().direct_space_state
	for i in 4:
		var query := PhysicsRayQueryParameters3D.create(from, to, occluder_mask)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return null
		var collider := hit.collider as Node3D
		if collider == null or not _is_smashable(collider):
			return null
		if _handled_ids.has(collider.get_instance_id()):
			# Already broken (its removal may still be pending): look past it.
			exclude.append(hit.rid)
			continue
		return collider
	return null


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

	# Something in the way to the target: stop and attack it first, then move on.
	if _plowing:
		var blocker := _probe_blocker(direction)
		if blocker != null:
			_begin_blocker_attack(blocker)
			return

	_moving = true
	_move_speed = speed
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
