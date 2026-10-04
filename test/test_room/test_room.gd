extends Node3D
## Stalker test room: build a scenario, then run the Stalker against it.
##
## Workflow
##   1. PLACE DUMMY   WASD move the Dummy, E place it.
##   2. READY         O  add an obstacle cube (ghost; WASD moves it, E places it,
##                       Esc cancels). Repeat as often as you like.
##                    Backspace removes the last cube, P picks the Dummy up again.
##   3. T             start the test. The Dummy is locked in place;
##                    WASD only turns it so the flashlight can be aimed, F toggles it.
##   4. T again       stops the test.
##   5. Dummy dies    the monster stops, is put at a random spot on the floor and
##                    waits. Press T to run again.
##
## Placement rules: cubes can not overlap each other, and cubes / Dummy /
## monsters keep a minimum distance so nothing spawns inside anything else.

enum Phase { PLACE_DUMMY, READY, PLACE_CUBE, RUNNING, RESETTING }
enum MonsterMode { STALKER, SEEKER, BOTH }

## Edge length of an obstacle cube (meters).
const CUBE_SIZE := 1.5
## The walkable navmesh reaches +-14.5; keep things inside it.
const NAV_EDGE := 14.5
## Dummy centre must stay this far from any cube surface (so the Stalker can
## still path next to it).
const DUMMY_CLEARANCE := 1.2
## Stalker centre must stay this far from any cube surface.
const STALKER_CLEARANCE := 1.0
## Seeker centre must stay this far from any cube surface.
const SEEKER_CLEARANCE := 1.0
## Minimum distance between the Dummy and the monster when placing.
const DUMMY_MONSTER_MIN := 2.5
## Random monster spawns are at least this far from the Dummy.
const RANDOM_MIN_DIST := 6.0
## Ghost cube speed while placing (m/s).
const GHOST_SPEED := 7.0

@onready var _debug_label: Label = $Debug/DebugLabel
@onready var _stalker: Stalker = $Stalker
@onready var _seeker_spawn: Marker3D = $SeekerSpawn
@onready var _subject: TestSubject = $TestSubject
@onready var _nav: TestRoomNav = $Room/Navigation

var _phase := Phase.PLACE_DUMMY
var _monster_mode := MonsterMode.STALKER
var _cubes: Array[StaticBody3D] = []
var _ghost: MeshInstance3D
var _ghost_material: StandardMaterial3D
var _cube_material: StandardMaterial3D
var _marker: MeshInstance3D
var _marker_material: StandardMaterial3D
var _last_ghost_pos := Vector3.ZERO
var _baking := false
var _message := ""
var _message_time := 0.0
var _seeker: Seeker = null
var _stalker_present := true
var _seeker_marker: MeshInstance3D


func _ready() -> void:
	_ensure_input_actions()
	_stalker.player_killed.connect(_on_stalker_killed)
	_nav.rebake_finished.connect(_on_rebake_finished)
	_build_materials()
	_build_marker()
	_apply_mode_presence()
	_enter_place_dummy()
	print("Stalker test room ready.  E place | O cube | T start/stop | Tab swap monster | F toggle light | Esc menu")


# ------------------------------------------------------------------- setup

func _build_materials() -> void:
	_cube_material = StandardMaterial3D.new()
	_cube_material.albedo_color = Color(0.55, 0.42, 0.32)
	_cube_material.roughness = 0.9

	_ghost_material = StandardMaterial3D.new()
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.albedo_color = Color(0.2, 1.0, 0.3, 0.45)

	_marker_material = StandardMaterial3D.new()
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.albedo_color = Color(0.2, 1.0, 0.3, 0.5)


## Flat disc under the Dummy that turns red when its spot is not allowed.
func _build_marker() -> void:
	var disc := CylinderMesh.new()
	disc.top_radius = 0.7
	disc.bottom_radius = 0.7
	disc.height = 0.02
	disc.material = _marker_material
	_marker = MeshInstance3D.new()
	_marker.mesh = disc
	_marker.visible = false
	add_child(_marker)

	# Orange disc where the Seeker will spawn (only shown in SEEKER / BOTH).
	var seeker_disc := CylinderMesh.new()
	seeker_disc.top_radius = 0.7
	seeker_disc.bottom_radius = 0.7
	seeker_disc.height = 0.02
	var seeker_disc_material := StandardMaterial3D.new()
	seeker_disc_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	seeker_disc_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	seeker_disc_material.albedo_color = Color(1.0, 0.55, 0.1, 0.5)
	seeker_disc.material = seeker_disc_material
	_seeker_marker = MeshInstance3D.new()
	_seeker_marker.mesh = seeker_disc
	_seeker_marker.visible = false
	add_child(_seeker_marker)
	_seeker_marker.global_position = Vector3(_seeker_spawn.global_position.x, 0.02, _seeker_spawn.global_position.z)


## Make sure the test-only input actions exist, so the room works even if
## project.godot does not define them yet.
func _ensure_input_actions() -> void:
	var defaults := {
		&"test_swap_monster": KEY_TAB,
		&"test_back_to_menu": KEY_ESCAPE,
	}
	for action: StringName in defaults:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = defaults[action]
		InputMap.action_add_event(action, key)


# ------------------------------------------------------------------- phases

func _enter_place_dummy() -> void:
	_phase = Phase.PLACE_DUMMY
	_subject.set_locked(false)
	_subject.input_enabled = true
	_marker.visible = true


func _enter_ready() -> void:
	_phase = Phase.READY
	_subject.set_locked(true)
	_subject.input_enabled = false
	_marker.visible = false


func _start_test() -> void:
	if _subject.is_in_group("dead"):
		_say("Dummy is respawning, wait a moment.")
		return
	if _baking:
		_say("Navmesh is still baking, wait a moment.")
		return
	_phase = Phase.RUNNING
	_subject.input_enabled = true  # WASD turns the Dummy so the torch can be aimed
	_spawn_monsters()
	_say("Test running.")


func _spawn_monsters() -> void:
	_clear_monsters()
	_apply_mode_presence()
	if _mode_has_stalker():
		_stalker.activate()
	if _mode_has_seeker():
		_seeker = _spawn_seeker()
		_seeker.activate()


func _spawn_seeker() -> Seeker:
	var seeker_scene := preload("res://entities/monsters/seeker/seeker.tscn")
	var seeker_instance := seeker_scene.instantiate() as Seeker
	seeker_instance.show_debug_label = true
	add_child(seeker_instance)
	# Tether (home) is the seeker spawn point.
	seeker_instance.place_at(_seeker_spawn.global_position)
	seeker_instance.killed_holder.connect(_on_seeker_killed_holder)
	seeker_instance.killed_monster.connect(_on_seeker_killed_monster)
	seeker_instance.destroyed_obstacle.connect(_on_seeker_destroyed_obstacle)
	return seeker_instance


func _clear_monsters() -> void:
	if _stalker and _stalker.is_inside_tree():
		_stalker.deactivate()
	_free_seeker()


func _free_seeker() -> void:
	if _seeker and is_instance_valid(_seeker):
		_seeker.get_parent().remove_child(_seeker)
		_seeker.queue_free()
	_seeker = null


func _mode_has_stalker() -> bool:
	return _monster_mode == MonsterMode.STALKER or _monster_mode == MonsterMode.BOTH


func _mode_has_seeker() -> bool:
	return _monster_mode == MonsterMode.SEEKER or _monster_mode == MonsterMode.BOTH


## The Stalker is a fixed node of this room, so "removing" it means hiding it
## and switching its body and processing off (and the reverse to bring it back).
func _set_stalker_present(present: bool) -> void:
	_stalker_present = present
	_stalker.visible = present
	_stalker.process_mode = Node.PROCESS_MODE_INHERIT if present else Node.PROCESS_MODE_DISABLED
	var body_shape := _stalker.get_node("Collision") as CollisionShape3D
	body_shape.set_deferred("disabled", not present)


func _apply_mode_presence() -> void:
	_set_stalker_present(_mode_has_stalker())
	_seeker_marker.visible = _mode_has_seeker()


## Stop the monster and put it somewhere random; it waits for the next T.
func _stop_test(message: String) -> void:
	_free_seeker()
	if _stalker and _stalker.is_inside_tree():
		if _mode_has_stalker():
			_set_stalker_present(true)
			_stalker.relocate(_random_stalker_position())
		else:
			_stalker.deactivate()
	_subject.input_enabled = false
	_phase = Phase.READY
	_say(message)


func _on_stalker_killed(_victim: Node3D) -> void:
	# Let the punch finish, then stop the Stalker so it does not keep killing
	# the Dummy when it respawns.
	_begin_reset(_stalker.punch_duration + 0.3, "Dummy died. Stalker moved to a random spot. Press T to run again.")


func _on_seeker_killed_holder(_source: Node3D) -> void:
	_begin_reset(1.0, "Seeker destroyed the torch and the Dummy died. Press T to run again.")


## The Stalker has no die() of its own, so the room takes it out of play.
func _on_seeker_killed_monster(monster: Node3D) -> void:
	if monster == _stalker:
		_stalker.deactivate()
		_set_stalker_present(false)
		_say("Seeker killed the Stalker.")


## A cube the Seeker smashed: forget it and let the navmesh open up.
func _on_seeker_destroyed_obstacle(obstacle: Node3D) -> void:
	_cubes.erase(obstacle)
	_request_rebake()
	_say("Seeker smashed a cube (%d left)." % _cubes.size())


func _begin_reset(delay: float, message: String) -> void:
	if _phase != Phase.RUNNING:
		return
	_phase = Phase.RESETTING
	_subject.input_enabled = false
	get_tree().create_timer(delay).timeout.connect(
		func() -> void:
			_stop_test(message),
		CONNECT_ONE_SHOT
	)


# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey

	# Handle physical Tab directly. This avoids relying on the runtime
	# InputMap action when switching enemy types.
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_TAB:
		_cycle_monster_mode()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed(&"test_back_to_menu") and not event.is_echo():
		if _phase == Phase.PLACE_CUBE:
			_cancel_cube_ghost()
		else:
			get_tree().change_scene_to_file("res://ui/menus/main_menu/main_menu.tscn")
		get_viewport().set_input_as_handled()
	else:
		if key == null or not key.pressed or key.echo:
			return
		print("key: ", OS.get_keycode_string(key.physical_keycode), "  phase: ", Phase.keys()[_phase], "  mode: ", MonsterMode.keys()[_monster_mode])
		match key.physical_keycode:
			KEY_E:
				if _phase == Phase.PLACE_DUMMY or _phase == Phase.PLACE_CUBE:
					_confirm_place()
				else:
					_say("E places the Dummy / a cube while you are placing one.")
			KEY_O:
				match _phase:
					Phase.PLACE_DUMMY:
						# Convenience: O also confirms the Dummy, then starts a cube.
						if _dummy_spot_valid():
							_enter_ready()
							_begin_cube_ghost()
						else:
							_say("Can't place the Dummy here (red disc). Move it, then press O.")
					Phase.READY:
						_begin_cube_ghost()
					Phase.PLACE_CUBE:
						_say("Already placing a cube: E to place, Esc to cancel.")
					_:
						_say("Stop the test first (T), then add cubes.")
			KEY_BACKSPACE:
				if _phase == Phase.READY:
					_remove_last_cube()
				else:
					_say("Backspace removes the last cube (only in READY mode).")
			KEY_P:
				if _phase == Phase.READY:
					_enter_place_dummy()
			KEY_T:
				match _phase:
					Phase.READY:
						_start_test()
					Phase.RUNNING:
						_stop_test("Test stopped. Monster moved to a random spot. Press T to run again.")
					Phase.PLACE_DUMMY:
						_say("Place the Dummy first (E).")
					Phase.PLACE_CUBE:
						_say("Place or cancel the cube first (E / Esc).")
			_:
				return
		get_viewport().set_input_as_handled()


func _cycle_monster_mode() -> void:
	if _phase == Phase.RUNNING:
		_say("Stop the test first (T) to change monster mode.")
		return
	_monster_mode = ((int(_monster_mode) + 1) % MonsterMode.size()) as MonsterMode
	_apply_mode_presence()
	_say("Monster mode: %s" % MonsterMode.keys()[_monster_mode])


func _confirm_place() -> void:
	match _phase:
		Phase.PLACE_DUMMY:
			if not _dummy_spot_valid():
				_say("Can't place the Dummy here (too close to a cube or the monster).")
				return
			_enter_ready()
			_say("Dummy placed. O = add cube, T = start.")
		Phase.PLACE_CUBE:
			if not _ghost_spot_valid():
				_say("Can't place a cube here.")
				return
			_place_cube()


# ------------------------------------------------------------------- cubes

func _begin_cube_ghost() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * CUBE_SIZE
	box.material = _ghost_material
	_ghost = MeshInstance3D.new()
	_ghost.mesh = box
	_ghost.position = Vector3(_last_ghost_pos.x, CUBE_SIZE * 0.5, _last_ghost_pos.z)
	add_child(_ghost)
	_phase = Phase.PLACE_CUBE
	_say("Cube ghost spawned in the middle of the floor. WASD move, E place.")


func _cancel_cube_ghost() -> void:
	_ghost.queue_free()
	_ghost = null
	_phase = Phase.READY


func _place_cube() -> void:
	var pos := _ghost.position
	_last_ghost_pos = pos
	_ghost.queue_free()
	_ghost = null

	var body := StaticBody3D.new()
	body.add_to_group("obstacle")
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3.ONE * CUBE_SIZE
	shape.shape = box_shape
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * CUBE_SIZE
	box.material = _cube_material
	mesh.mesh = box
	body.add_child(mesh)
	# Child of the navigation region so the navmesh bake carves around it.
	_nav.add_child(body)
	body.global_position = pos
	_cubes.append(body)

	_phase = Phase.READY
	_request_rebake()
	_say("Cube placed (%d total)." % _cubes.size())


func _remove_last_cube() -> void:
	if _cubes.is_empty():
		_say("No cubes to remove.")
		return
	var cube: StaticBody3D = _cubes.pop_back()
	# Take it out of the tree right away so the rebake no longer sees it.
	cube.get_parent().remove_child(cube)
	cube.queue_free()
	_request_rebake()
	_say("Cube removed (%d left)." % _cubes.size())


func _request_rebake() -> void:
	_baking = true
	_nav.call_deferred("rebake")
	# Safety net: never stay blocked on a bake that never reports back.
	get_tree().create_timer(10.0).timeout.connect(
		func() -> void:
			if _baking:
				_baking = false
				push_warning("Navmesh rebake did not report back in 10 s; continuing."),
		CONNECT_ONE_SHOT
	)


func _on_rebake_finished() -> void:
	_baking = false


# --------------------------------------------------------------- validation

## Distance in XZ from a point to the nearest edge of a cube centred at c.
func _dist_to_cube(p: Vector3, c: Vector3) -> float:
	var half := CUBE_SIZE * 0.5
	var dx := maxf(absf(p.x - c.x) - half, 0.0)
	var dz := maxf(absf(p.z - c.z) - half, 0.0)
	return sqrt(dx * dx + dz * dz)


func _min_dist_to_cubes(p: Vector3) -> float:
	var best := INF
	for cube in _cubes:
		best = minf(best, _dist_to_cube(p, cube.global_position))
	return best


func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _ghost_spot_valid() -> bool:
	if _ghost == null:
		return false
	var p := _ghost.position
	for cube in _cubes:
		var c := cube.global_position
		if absf(p.x - c.x) < CUBE_SIZE and absf(p.z - c.z) < CUBE_SIZE:
			return false  # overlaps another cube
	if _dist_to_cube(_subject.global_position, p) < DUMMY_CLEARANCE:
		return false
	if _stalker_present and _dist_to_cube(_stalker.global_position, p) < STALKER_CLEARANCE:
		return false
	if _mode_has_seeker() and _dist_to_cube(_seeker_spawn.global_position, p) < SEEKER_CLEARANCE:
		return false
	return true


func _dummy_spot_valid() -> bool:
	var p := _subject.global_position
	if _min_dist_to_cubes(p) < DUMMY_CLEARANCE:
		return false
	if _stalker_present and _flat_dist(p, _stalker.global_position) < DUMMY_MONSTER_MIN:
		return false
	if _mode_has_seeker() and _flat_dist(p, _seeker_spawn.global_position) < DUMMY_MONSTER_MIN:
		return false
	return true


func _random_stalker_position() -> Vector3:
	var dummy_pos := _subject.global_position
	for i in 100:
		var p := Vector3(randf_range(-13.0, 13.0), 0.0, randf_range(-13.0, 13.0))
		if _flat_dist(p, dummy_pos) < RANDOM_MIN_DIST:
			continue
		if _min_dist_to_cubes(p) < STALKER_CLEARANCE + 0.5:
			continue
		return p
	# Fallback: the corner farthest from the Dummy.
	return Vector3(
		13.0 if dummy_pos.x < 0.0 else -13.0,
		0.0,
		13.0 if dummy_pos.z < 0.0 else -13.0
	)


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	match _phase:
		Phase.PLACE_DUMMY:
			var p := _subject.global_position
			p.x = clampf(p.x, -13.5, 13.5)
			p.z = clampf(p.z, -13.5, 13.5)
			_subject.global_position = p
			_marker.global_position = Vector3(p.x, 0.02, p.z)
			var ok := _dummy_spot_valid()
			_marker_material.albedo_color = Color(0.2, 1.0, 0.3, 0.5) if ok else Color(1.0, 0.15, 0.15, 0.6)
		Phase.PLACE_CUBE:
			if _ghost:
				var half := CUBE_SIZE * 0.5
				var limit := NAV_EDGE - half
				var step := _input_world_vector() * GHOST_SPEED * delta
				var q := _ghost.position + step
				q.x = clampf(q.x, -limit, limit)
				q.z = clampf(q.z, -limit, limit)
				q.y = half
				_ghost.position = q
				var ok := _ghost_spot_valid()
				_ghost_material.albedo_color = Color(0.2, 1.0, 0.3, 0.45) if ok else Color(1.0, 0.15, 0.15, 0.55)
	_message_time = maxf(_message_time - delta, 0.0)
	_update_label()


## WASD as a world-space direction on the floor, relative to the fixed camera.
func _input_world_vector() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam := get_viewport().get_camera_3d()
	if input.length() < 0.01 or cam == null:
		return Vector3.ZERO
	var right := cam.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var back := cam.global_transform.basis.z
	back.y = 0.0
	back = back.normalized()
	return (right * input.x + back * input.y).normalized()


# --------------------------------------------------------------------- label

func _say(text: String) -> void:
	_message = text
	_message_time = 5.0
	print(text)


func _update_label() -> void:
	var phase_name := ""
	var help := ""
	match _phase:
		Phase.PLACE_DUMMY:
			phase_name = "1. PLACE DUMMY"
			help = "WASD move Dummy  |  E place"
		Phase.READY:
			phase_name = "READY"
			help = "O add cube  |  Backspace remove last  |  P move Dummy  |  T start"
		Phase.PLACE_CUBE:
			phase_name = "PLACING CUBE"
			help = "WASD move cube  |  E place  |  Esc cancel"
		Phase.RUNNING:
			phase_name = "RUNNING"
			help = "WASD aim torch  |  F light  |  T stop"
		Phase.RESETTING:
			phase_name = "RESETTING..."
			help = ""
	var nav_state := "baking..." if _baking else "ready"
	var dead := " (dead)" if _subject.is_in_group("dead") else ""
	var monster_lines := PackedStringArray()
	if _stalker_present:
		monster_lines.append("Stalker: " + _stalker.state_name())
	if _seeker and is_instance_valid(_seeker):
		monster_lines.append("Seeker: " + _seeker.state_name())
	elif _mode_has_seeker():
		monster_lines.append("Seeker: WAITING (press T)")
	var text := "Mode: %s  [Tab]\n%s\nLight: %s%s  [F]\nCubes: %d   Navmesh: %s\n%s  [Esc] menu" % [
		MonsterMode.keys()[_monster_mode],
		"\n".join(monster_lines),
		"ON" if _subject.flashlight_is_on else "OFF",
		dead,
		_cubes.size(),
		nav_state,
		help,
	]
	if _message_time > 0.0:
		text += "\n>> " + _message
	_debug_label.text = text

