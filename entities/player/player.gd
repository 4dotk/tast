class_name Player
extends CharacterBody3D
## Silent Hill 3-style player controls.
##
## The Player is a character. The flashlight is a separate physical object.
## While held it is parented to a BoneAttachment3D on the hand bone, so it
## follows the animation by itself (no per-frame syncing).
##
## W / S : move forward / back
## A / D : turn, or strafe while locked on
## Q     : toggle lock-on (needs an enemy in front of you)
## E     : interact, or drop/pick up the flashlight
## F     : flashlight on/off (only while you are holding it)

## --- Speed balance (monster speeds are NOT touched) ---------------------------
## Stalker: 4.4 m/s nominal, but each lurch jitters its heading by up to
## +-0.4 rad, so it really closes in at about 4.4 * sin(0.4)/0.4 = 4.3 m/s,
## less with its snaps and freezes. The Seeker is a slower brute: it approaches
## the light at 3.5 m/s and loses time stopping to smash obstacles.
## Holding the torch at 3.4 lets the Stalker gain on you at ~0.9 m/s while the
## Seeker barely gains; dropping the torch (3.75) lets you pull away from the
## Seeker, while the Stalker still gains slowly.
const MOVE_SPEED_HELD := 3.4
const MOVE_SPEED_FREE := 3.75
const BACKWARD_FACTOR := 0.6
const STRAFE_FACTOR := 0.75
const ACCEL := 25.0
const DECEL := 30.0
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
## Horizontal speed above which the beam is fixed to the body instead of
## following the swinging torch.
const BEAM_FIX_SPEED := 0.1

## Animation names inside Player.glb (7 clips).
const ANIM_IDLE := "Player_Idle"
const ANIM_IDLE_HELD := "Player_Idle_Held"
const ANIM_RUN := "Player_Running"
const ANIM_RUN_HELD := "Player_Running_Held"
const ANIM_PICKUP := "Player_PickUp"
const ANIM_DEATH := "Player_Death"
const ANIM_GETUP := "Player_GetUp"
const LOOPING_ANIMS := [ANIM_IDLE, ANIM_IDLE_HELD, ANIM_RUN, ANIM_RUN_HELD]
const ANIM_BLEND := 0.2
## Root travel (meters) below which a position track is not treated as motion.
const ROOT_MOTION_THRESHOLD := 0.01
## Used only if a run clip's natural speed could not be measured.
const RUN_FALLBACK_SPEED := 3.0

@export var flashlight_scene: PackedScene = preload(
	"res://entities/props/flashlight/flashlight.tscn"
)

## How long (seconds) the Player stays dead before respawning.
@export var respawn_delay := 2.5

## During the PickUp animation the torch jumps into the hand at this point
## (0.0 = start of the clip, 1.0 = end). Tweak to match your animation.
@export_range(0.0, 1.0) var pickup_attach_fraction := 0.5
## Playback speed of Player_PickUp (7.2 s at x1). Used for picking up AND placing.
@export_range(0.5, 6.0) var pickup_anim_speed := 3.0
## Control returns at this fraction of the clip (trims a long tail).
@export_range(0.3, 1.0) var pickup_end_fraction := 0.9
## Playback multiplier for Player_Running_Held on top of the ground-speed match
## (1.0 = feet exactly match the ground). Lower = calmer run cycle.
@export_range(0.3, 2.0) var run_held_anim_scale := 1.3

@export_group("Placing")
## The torch is L-shaped (handle down, head forward). To lie flat it is rolled
## around its beam axis so the handle ends up on its side. Flip the sign
## (90 / -90) to choose which side the handle falls to; use 0 for no roll.
@export_range(-180.0, 180.0) var dropped_roll_degrees := 90.0

@export_group("Hand")
## Hand that holds the torch during Idle_Held / Running_Held.
@export var hand_bone := "hand.l"
## Hand the PickUp / place clip uses.
@export var pickup_hand_bone := "hand.r"
## FALLBACK ONLY (used if player.tscn has no Flashlight under HeldMount).
## The real held pose is the Flashlight node's Transform under HeldMount in
## player.tscn: edit it in the editor, it is read at startup and reused on
## every pick up / respawn.
@export var held_position := Vector3.ZERO
@export var held_rotation_degrees := Vector3.ZERO
## Same, but for the pick up / place hand.
@export var pickup_position := Vector3.ZERO
@export var pickup_rotation_degrees := Vector3.ZERO

## Respawn goes straight to Idle. Turn on to play Player_GetUp after a respawn.
@export var play_getup_on_respawn := false

@export_group("Debug")
## Prints speed / animation / chase timings to the Output panel.
@export var debug_log := true
@export var debug_log_interval := 1.0

@onready var _body: Node3D = $Body

var _flashlight: Flashlight
var _lock_target: Node3D
var _dead := false
## True while a one-shot animation (pick up / get up) owns the character.
var _busy := false
var _move_input := 0.0
var _anim: AnimationPlayer
var _body_rest := Transform3D.IDENTITY
## Clip name -> meters/second the clip covers on its own (root motion removed).
var _clip_speed := {}
var _log_time := 0.0
var _log_enemy_dist := -1.0
var _logged_enemy_count := 0
var _spawn_transform := Transform3D.IDENTITY
## Bumped whenever an action is started or cancelled (death), so old
## coroutines (pick up / place) stop themselves.
var _action_id := 0
var _hand_mount: BoneAttachment3D
var _pickup_mount: BoneAttachment3D
## Flashlight's local transform under HeldMount, captured from player.tscn.
## Includes the scale that cancels the skeleton's 0.01 import scale.
var _held_transform := Transform3D.IDENTITY

signal died
## Emitted during respawn, after the torch was put back in the hand. A level can take it away again.
signal respawned
## Emitted when lock-on acquires a target, or with null when it is released.
signal lock_target_changed(target: Node3D)


func _ready() -> void:
	add_to_group("player")
	_spawn_transform = global_transform

	_body_rest = _body.transform
	_setup_animation()
	_setup_hand_mounts()
	_ensure_flashlight()
	if is_instance_valid(_flashlight):
		_flashlight.set_beam_reference(self)
	# Spawn pose is always Idle (never GetUp).
	_update_animation()
	if debug_log:
		_log_balance.call_deferred()


# ------------------------------------------------------------- animation

func _setup_animation() -> void:
	_anim = _body.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim == null:
		push_error("Player.glb has no AnimationPlayer - check the import.")
		return

	# glTF clips import as one-shots; make the locomotion clips loop.
	for anim_name in _anim.get_animation_list():
		var anim := _anim.get_animation(anim_name)
		if anim == null:
			continue
		anim.loop_mode = (
			Animation.LOOP_LINEAR if anim_name in LOOPING_ANIMS else Animation.LOOP_NONE
		)

	_anim.autoplay = ""
	_anim.stop()
	_make_seamless_loops()
	_strip_root_motion()


## The exported loop clips are not cut at the real loop point:
##  - Player_Running ends on a copy of its first pose (that pose shows twice per
##    loop) and its first key sits at t=0.033, so the pose is also held at the start.
##  - Player_Running_Held is 31 frames long but the gait repeats every 20, so the
##    clip is cut off mid-stride and pops when it wraps.
## For each looping clip, find the later frame whose pose matches frame 0, shift
## the keys so the clip starts at t=0, and end the clip exactly on that frame.
func _make_seamless_loops() -> void:
	for clip_name in LOOPING_ANIMS:
		if not _anim.has_animation(clip_name):
			continue
		var anim := _anim.get_animation(clip_name)
		if anim.has_meta("player_loop_fixed"):
			continue
		anim.set_meta("player_loop_fixed", true)

		# Rotation tracks that really animate (more than a constant 2-key track).
		var tracks: Array[int] = []
		var key_count := 0
		for i in anim.get_track_count():
			if anim.track_get_type(i) == Animation.TYPE_ROTATION_3D:
				key_count = maxi(key_count, anim.track_get_key_count(i))
		if key_count < 6:
			continue
		for i in anim.get_track_count():
			if (
				anim.track_get_type(i) == Animation.TYPE_ROTATION_3D
				and anim.track_get_key_count(i) == key_count
			):
				tracks.append(i)

		var t0 := anim.track_get_key_time(tracks[0], 0)
		var best_key := -1
		var best_diff := INF
		# Skip the first quarter so we never "match" a neighbouring frame.
		for k in range(int(key_count / 4.0), key_count):
			var total := 0.0
			for i in tracks:
				var q0: Quaternion = anim.track_get_key_value(i, 0)
				var qk: Quaternion = anim.track_get_key_value(i, k)
				total += 2.0 * acos(minf(1.0, absf(q0.dot(qk))))
			var diff := rad_to_deg(total / float(tracks.size()))
			# Earliest near-exact match wins (strictly better by > 0.05 deg to replace).
			if diff < best_diff - 0.05:
				best_diff = diff
				best_key = k

		if best_key < 0 or best_diff > 1.0:
			if debug_log:
				print("[Player] '%s': no matching loop frame (best %.2f deg) - left as is" % [
					clip_name, best_diff])
			continue

		var new_length := anim.track_get_key_time(tracks[0], best_key) - t0
		var old_length := anim.length
		for i in anim.get_track_count():
			var n := anim.track_get_key_count(i)
			for k in range(n - 1, -1, -1):
				var t := anim.track_get_key_time(i, k) - t0
				if t > new_length + 0.001:
					anim.track_remove_key(i, k)
				else:
					anim.track_set_key_time(i, k, maxf(t, 0.0))
		anim.length = new_length
		if debug_log:
			print("[Player] loop fixed '%s': %.3fs -> %.3fs (frame %d matches frame 0, diff %.3f deg)" % [
				clip_name, old_length, new_length, best_key, best_diff])


## The glb's run clips carry root motion (the model root slides ~5 m per loop,
## then snaps back), which fights the CharacterBody3D and causes the
## "forward, back, forward" jitter. Flatten horizontal travel on every position
## track (vertical bob is kept) and remember how fast each clip really moves,
## so playback can be matched to the Player's real speed.
func _strip_root_motion() -> void:
	var root := _anim.get_node_or_null(_anim.root_node)
	if root == null:
		return
	var ref_inv := global_transform.affine_inverse()

	for clip_name in _anim.get_animation_list():
		var anim := _anim.get_animation(clip_name)
		if anim == null:
			continue
		if anim.has_meta("player_root_stripped"):
			_clip_speed[clip_name] = anim.get_meta("player_root_stripped")
			continue

		var clip_travel := 0.0
		for i in anim.get_track_count():
			if anim.track_get_type(i) != Animation.TYPE_POSITION_3D:
				continue
			var keys := anim.track_get_key_count(i)
			if keys < 2:
				continue
			var to_ref := _track_to_ref(root, anim.track_get_path(i), ref_inv)
			var to_track := to_ref.affine_inverse()
			var first: Vector3 = to_ref * anim.track_get_key_value(i, 0)
			var travel := 0.0
			for k in keys:
				var m: Vector3 = to_ref * anim.track_get_key_value(i, k)
				travel = maxf(travel, Vector2(m.x - first.x, m.z - first.z).length())
			if travel <= ROOT_MOTION_THRESHOLD:
				continue
			for k in keys:
				var m: Vector3 = to_ref * anim.track_get_key_value(i, k)
				anim.track_set_key_value(i, k, to_track * Vector3(first.x, m.y, first.z))
			# After _make_seamless_loops the last key sits exactly on the loop
			# point, so the measured travel already is the travel per loop.
			clip_travel = maxf(clip_travel, travel)
			if debug_log:
				print("[Player] removed %.2f m root motion from '%s' in '%s'" % [
					travel, anim.track_get_path(i), clip_name])

		var speed := clip_travel / anim.length if anim.length > 0.01 else 0.0
		anim.set_meta("player_root_stripped", speed)
		_clip_speed[clip_name] = speed


## Transform that converts a position track's values into the Player's space.
func _track_to_ref(root: Node, path: NodePath, ref_inv: Transform3D) -> Transform3D:
	var node := root.get_node_or_null(NodePath(path.get_concatenated_names())) as Node3D
	if node == null:
		return Transform3D.IDENTITY
	if node is Skeleton3D and path.get_subname_count() > 0:
		var skel := node as Skeleton3D
		var space := ref_inv * skel.global_transform
		var bone := skel.find_bone(String(path.get_subname(0)))
		if bone >= 0 and skel.get_bone_parent(bone) >= 0:
			space = space * skel.get_bone_global_rest(skel.get_bone_parent(bone))
		return space
	if node.get_parent() is Node3D:
		return ref_inv * (node.get_parent() as Node3D).global_transform
	return ref_inv * node.global_transform


## Meters/second the clip covers at playback speed 1.
func _natural_speed(anim_name: StringName) -> float:
	var v: float = _clip_speed.get(String(anim_name), 0.0)
	return v if v > 0.3 else RUN_FALLBACK_SPEED


func _play(anim_name: StringName, speed := 1.0, blend := ANIM_BLEND) -> void:
	if _anim == null:
		return
	if not _anim.has_animation(anim_name):
		push_warning("Missing animation: %s" % anim_name)
		return
	_anim.speed_scale = speed
	if _anim.current_animation != anim_name or not _anim.is_playing():
		_anim.play(anim_name, blend, 1.0, speed < 0.0)


func _anim_length(anim_name: StringName) -> float:
	if _anim != null and _anim.has_animation(anim_name):
		return _anim.get_animation(anim_name).length
	return 0.0


## Idle (or busy): the beam follows the torch. Running: the beam is fixed to the
## body so the arm swing does not sweep it. The torch model is never affected.
func _update_beam_mode() -> void:
	if not is_instance_valid(_flashlight):
		return
	var moving := Vector2(velocity.x, velocity.z).length() > BEAM_FIX_SPEED
	_flashlight.set_beam_fixed(moving and not _busy)


## Idle / run, with or without the flashlight in hand. Run playback speed is
## matched to the real ground speed so the feet never slide.
func _update_animation() -> void:
	if _dead or _busy:
		return

	var held := is_instance_valid(_flashlight) and _flashlight.is_held()
	var h_speed := Vector2(velocity.x, velocity.z).length()

	if h_speed > 0.1:
		var clip := ANIM_RUN_HELD if held else ANIM_RUN
		var playback := clampf(h_speed / _natural_speed(clip), 0.3, 3.0)
		if held:
			playback *= run_held_anim_scale
		# Moving backwards plays the run clip in reverse.
		var backwards := Vector3(velocity.x, 0.0, velocity.z).dot(-global_transform.basis.z) < -0.01
		_play(clip, -playback if backwards else playback)
	else:
		_play(ANIM_IDLE_HELD if held else ANIM_IDLE)


func get_move_speed() -> float:
	var held := is_instance_valid(_flashlight) and _flashlight.is_held()
	return MOVE_SPEED_HELD if held else MOVE_SPEED_FREE


# ------------------------------------------------------------- torch mounting

## Uses the BoneAttachment3D already present in player.tscn.
## The flashlight is always held by the left hand.
func _setup_hand_mounts() -> void:
	var skeleton := _body.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		push_error("No Skeleton3D under Body - torch will not follow the hand.")
		return

	if skeleton.find_bone(hand_bone) < 0:
		push_error("Hand bone '%s' not found." % hand_bone)
		return

	# player.tscn contains HeldMount under Skeleton3D and it is already
	# configured for hand.l. Reuse it instead of creating duplicate mounts.
	_hand_mount = skeleton.find_child("HeldMount", false, false) as BoneAttachment3D
	if _hand_mount == null:
		push_error("Could not find Skeleton3D/HeldMount in player.tscn.")
		return

	_hand_mount.bone_name = hand_bone
	_pickup_mount = _hand_mount


## Parents the torch to the left-hand bone and restores the held pose that was
## authored in player.tscn (position, rotation AND scale in bone space).
func _mount_flashlight(_to_pickup_hand := false) -> void:
	if not is_instance_valid(_flashlight):
		return
	if _hand_mount == null:
		return

	if _flashlight.get_parent() != _hand_mount:
		_flashlight.reparent(_hand_mount, false)
		_flashlight.transform = _held_transform

	_flashlight.set_held(true)


func _ensure_flashlight() -> void:
	if is_instance_valid(_flashlight):
		return
	if _hand_mount == null:
		return

	# Prefer the Flashlight instance placed under HeldMount in player.tscn and
	# remember its transform: this is the single source of truth for the held pose.
	_flashlight = _hand_mount.find_child("Flashlight", false, false) as Flashlight
	if is_instance_valid(_flashlight):
		_held_transform = _flashlight.transform
		_flashlight.set_held(true)
		return

	# Fallback if the flashlight instance was removed from player.tscn.
	_flashlight = flashlight_scene.instantiate() as Flashlight
	if _flashlight == null:
		push_error("Failed to instantiate the Flashlight scene.")
		return

	# The skeleton sits under a 0.01-scaled import root (bones are in cm), so
	# anything on a bone needs the inverse scale to be metre-sized.
	var comp := 1.0 / _hand_mount.global_transform.basis.get_scale().x
	_held_transform = Transform3D(
		Basis.from_euler(held_rotation_degrees * (PI / 180.0)).scaled(Vector3.ONE * comp),
		held_position
	)
	_flashlight.name = "Flashlight"
	_hand_mount.add_child(_flashlight)
	_flashlight.transform = _held_transform
	_flashlight.set_held(true)


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return

	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	if _dead or _busy:
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

	if _lock_target != null and not _busy:
		_face_lock_target(delta)

	_update_animation()
	_update_beam_mode()
	if debug_log:
		_log_tick(delta)


func _handle_movement(delta: float) -> void:
	var forward: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x

	var turn_input := 0.0
	if not _busy:
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
	if not _busy:
		if Input.is_key_pressed(KEY_W):
			move_input += 1.0
		if Input.is_key_pressed(KEY_S):
			move_input -= 1.0
	_move_input = move_input

	var direction: Vector3 = forward * move_input + right * strafe_input
	if direction.length_squared() > 1.0:
		direction = direction.normalized()

	# Slower backwards / sideways; speed depends on holding the torch.
	var fwd_amount := direction.dot(forward)
	var side_amount := direction.dot(right)
	var target: Vector3 = (
		forward * fwd_amount * (1.0 if fwd_amount >= 0.0 else BACKWARD_FACTOR)
		+ right * side_amount * STRAFE_FACTOR
	) * get_move_speed()

	# Short ramp up/down so the animation never fights an instant velocity step.
	var rate := ACCEL if target.length_squared() > 0.0001 else DECEL
	var horizontal := Vector2(velocity.x, velocity.z).move_toward(
		Vector2(target.x, target.z), rate * delta
	)
	velocity.x = horizontal.x
	velocity.z = horizontal.y

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


## Shared start of pick up / place: lock the character and start the clip.
## Returns the action id.
func _begin_flashlight_action() -> int:
	_busy = true
	velocity.x = 0.0
	velocity.z = 0.0
	_set_lock_target(null)
	_action_id += 1
	_play(ANIM_PICKUP, pickup_anim_speed, 0.1)
	return _action_id


func _end_flashlight_action() -> void:
	_busy = false
	_update_animation()


func _action_times() -> Dictionary:
	var clip := _anim_length(ANIM_PICKUP)
	var speed := pickup_anim_speed
	return {
		"touch": clip * pickup_attach_fraction / speed,
		"total": clip * pickup_end_fraction / speed,
	}


func _action_alive(id: int) -> bool:
	return id == _action_id and not _dead


func _wait(seconds: float) -> void:
	await get_tree().create_timer(maxf(seconds, 0.001)).timeout


func _drop_flashlight() -> void:
	var world := get_parent()
	if world == null:
		return

	var id := _begin_flashlight_action()
	# The place clip uses the other hand: carry the torch in it.
	_mount_flashlight(true)
	var times := _action_times()
	var touch: float = times["touch"]
	var total: float = times["total"]
	if debug_log:
		print("[Player %s] PLACE start: clip %.2fs x%.1f -> release %.2fs, control back %.2fs" % [
			_now(), _anim_length(ANIM_PICKUP), pickup_anim_speed, touch, total])

	await _wait(touch)
	if not _action_alive(id):
		return

	# Set it down right below the hand, level on the floor.
	var ground := Transform3D(
		(
			global_transform.basis
			* Basis(Vector3.UP, PI * 0.5)
			# The beam is the torch's local +X axis: roll around it to lay it flat.
			* Basis(Vector3.RIGHT, deg_to_rad(dropped_roll_degrees))
		),
		Vector3(
			_flashlight.global_position.x,
			global_position.y + _flashlight.dropped_height,
			_flashlight.global_position.z
		)
	)
	_flashlight.reparent(world, true)
	_flashlight.global_transform = ground
	_flashlight.set_held(false)

	await _wait(total - touch)
	if not _action_alive(id):
		return
	_end_flashlight_action()
	if debug_log:
		print("[Player %s] PLACE done" % _now())


func _pick_up_flashlight() -> void:
	var id := _begin_flashlight_action()
	var times := _action_times()
	var touch: float = times["touch"]
	var total: float = times["total"]
	if debug_log:
		print("[Player %s] PICK UP start: clip %.2fs x%.1f -> in hand %.2fs, control back %.2fs" % [
			_now(), _anim_length(ANIM_PICKUP), pickup_anim_speed, touch, total])

	await _wait(touch)
	if not _action_alive(id):
		return
	_mount_flashlight(true)

	await _wait(total - touch)
	if not _action_alive(id):
		return
	# Back to the normal holding hand for Idle_Held / Running_Held.
	_mount_flashlight(false)
	_end_flashlight_action()
	if debug_log:
		print("[Player %s] PICK UP done" % _now())


func is_flashlight_on() -> bool:
	return is_instance_valid(_flashlight) and _flashlight.is_light_on()


func get_flashlight() -> Flashlight:
	return _flashlight


func die(_attacker_position: Vector3 = Vector3.INF) -> void:
	if _dead:
		return

	_dead = true
	_busy = false
	_action_id += 1
	# A torch in the hand stays attached and falls with the body, light off.
	if is_instance_valid(_flashlight) and _flashlight.is_held():
		_flashlight.set_light_on(false)
		_flashlight.set_beam_fixed(false)
	_set_lock_target(null)
	add_to_group("dead")
	velocity = Vector3.ZERO
	died.emit()

	# Play the death clip (it holds its last frame), then wait for the
	# respawn delay - but never cut the animation short.
	_play(ANIM_DEATH)
	var wait := maxf(respawn_delay, _anim_length(ANIM_DEATH))
	await get_tree().create_timer(wait).timeout
	_respawn()


func _respawn() -> void:
	if not _dead:
		return

	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	# Death clip may leave the model root displaced / rotated.
	_body.transform = _body_rest

	if is_instance_valid(_flashlight):
		_mount_flashlight(false)
		_flashlight.set_light_on(true)
	respawned.emit()

	if play_getup_on_respawn:
		# Stay "dead" (immune, no input) until the get-up clip is finished.
		_busy = true
		_play(ANIM_GETUP, 1.0, 0.0)
		await get_tree().create_timer(_anim_length(ANIM_GETUP)).timeout
		_busy = false

	_dead = false
	remove_from_group("dead")
	# Respawn pose is Idle, like the very first spawn.
	var held_now := is_instance_valid(_flashlight) and _flashlight.is_held()
	_play(ANIM_IDLE_HELD if held_now else ANIM_IDLE, 1.0, 0.0)
	if _anim != null:
		_anim.advance(0.0)


# ------------------------------------------------------------------ logging

func _now() -> String:
	return "%.2fs" % (Time.get_ticks_msec() / 1000.0)


## One-time table of speeds so the chase balance can be read at a glance.
func _log_balance() -> void:
	print("[Player %s] ===== speed balance =====" % _now())
	print("[Player] held=%.2f m/s  free=%.2f m/s  back x%.2f  strafe x%.2f" % [
		MOVE_SPEED_HELD, MOVE_SPEED_FREE, BACKWARD_FACTOR, STRAFE_FACTOR])
	for clip in [ANIM_RUN, ANIM_RUN_HELD]:
		if _anim != null and _anim.has_animation(clip):
			var nat := _natural_speed(clip)
			print("[Player] clip %s: length %.2fs, natural %.2f m/s -> playback x%.2f at held / x%.2f at free" % [
				clip, _anim.get_animation(clip).length, nat,
				MOVE_SPEED_HELD / nat, MOVE_SPEED_FREE / nat])
	_log_enemy_balance()


func _log_enemy_balance() -> void:
	var enemies := get_tree().get_nodes_in_group("enemies")
	_logged_enemy_count = enemies.size()
	for enemy in enemies:
		var chase = enemy.get("move_speed")
		var jitter = enemy.get("heading_jitter")
		if chase == null:
			chase = enemy.get("approach_speed")
		if chase == null:
			continue
		var nominal := float(chase)
		var effective := nominal
		if jitter != null and float(jitter) > 0.001:
			# Heading jitter wastes some speed: mean of cos over +-jitter.
			effective = nominal * sin(float(jitter)) / float(jitter)
		var gap_held := effective - MOVE_SPEED_HELD
		var gap_free := effective - MOVE_SPEED_FREE
		print("[Player %s] %s chase %.2f (effective ~%.2f) m/s | vs held %.2f: %+.2f m/s -> %s per 10 m | vs free %.2f: %+.2f m/s -> %s" % [
			_now(), enemy.name, nominal, effective, MOVE_SPEED_HELD, gap_held,
			_catch_time(gap_held, 10.0), MOVE_SPEED_FREE, gap_free,
			_catch_time(gap_free, 10.0)])


func _catch_time(closing: float, gap: float) -> String:
	return "%.0fs" % (gap / closing) if closing > 0.01 else "never"


func _log_tick(delta: float) -> void:
	_log_time += delta
	if _log_time < debug_log_interval:
		return
	var dt := _log_time
	_log_time = 0.0

	# Enemies spawn after the Player: print their balance once they exist.
	if get_tree().get_nodes_in_group("enemies").size() != _logged_enemy_count:
		_log_enemy_balance()

	var h_speed := Vector2(velocity.x, velocity.z).length()
	var nearest := INF
	var nearest_name := "-"
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if enemy is Node3D:
			var d := (enemy as Node3D).global_position.distance_to(global_position)
			if d < nearest:
				nearest = d
				nearest_name = enemy.name
	var closing := 0.0
	if _log_enemy_dist >= 0.0 and nearest < INF:
		closing = (_log_enemy_dist - nearest) / dt
	_log_enemy_dist = nearest if nearest < INF else -1.0

	print("[Player %s] speed %.2f/%.2f m/s | anim %s x%.2f | nearest %s %.1f m (closing %+.2f m/s) | held=%s busy=%s" % [
		_now(), h_speed, get_move_speed(),
		_anim.current_animation if _anim != null else "-",
		_anim.speed_scale if _anim != null else 0.0,
		nearest_name, nearest if nearest < INF else -1.0, closing,
		is_instance_valid(_flashlight) and _flashlight.is_held(), _busy])
