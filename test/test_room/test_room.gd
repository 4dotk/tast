extends Node3D
## Stalker test room: build a scenario, then run the Stalker against it.
##
## Workflow
##   1. PLACE DUMMY   WASD move the Dummy, E place it.
##   2. READY         O  add an obstacle cube (ghost; WASD moves it, E places it,
##                       Esc cancels). Repeat as often as you like.
##                    Backspace removes the last cube, P picks the Dummy up again.
##   3. T             start the Stalker test. The Dummy is locked in place;
##                    WASD only turns it so the flashlight can be aimed, F toggles it.
##   4. T again       stops the test.
##   5. Dummy dies    the Stalker stops, is put at a random spot on the floor and
##                    waits. Press T to run again.
##
## Placement rules: cubes can not overlap each other, and cubes / Dummy /
## Stalker keep a minimum distance so nothing spawns inside anything else.

enum Phase { PLACE_DUMMY, READY, PLACE_CUBE, RUNNING, RESETTING }

## Edge length of an obstacle cube (meters).
const CUBE_SIZE := 1.5
## The walkable navmesh reaches +-14.5; keep things inside it.
const NAV_EDGE := 14.5
## Dummy centre must stay this far from any cube surface (so the Stalker can
## still path next to it).
const DUMMY_CLEARANCE := 1.2
## Stalker centre must stay this far from any cube surface.
const STALKER_CLEARANCE := 1.0
## Minimum distance between the Dummy and the Stalker when placing.
const DUMMY_STALKER_MIN := 2.5
## Random Stalker spawns are at least this far from the Dummy.
const RANDOM_MIN_DIST := 6.0
## Ghost cube speed while placing (m/s).
const GHOST_SPEED := 7.0

@onready var _debug_label: Label = $Debug/DebugLabel
@onready var _stalker: Stalker = $Stalker
@onready var _subject: TestSubject = $TestSubject
@onready var _nav: TestRoomNav = $Room/Navigation

var _phase := Phase.PLACE_DUMMY
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


func _ready() -> void:
	_stalker.player_killed.connect(_on_stalker_killed)
	_nav.rebake_finished.connect(_on_rebake_finished)
	_build_materials()
	_build_marker()
	_enter_place_dummy()
	print("Stalker test room ready.  E place | O cube | T start/stop")


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
	_stalker.activate()
	_say("Test running.")


## Stop the Stalker and put it somewhere random; it waits for the next T.
func _stop_test(message: String) -> void:
	_stalker.relocate(_random_stalker_position())
	_subject.input_enabled = false
	_phase = Phase.READY
	_say(message)


func _on_stalker_killed(_victim: Node3D) -> void:
	if _phase != Phase.RUNNING:
		return
	# Let the punch finish, then stop the Stalker so it does not keep killing
	# the Dummy when it respawns.
	_phase = Phase.RESETTING
	_subject.input_enabled = false
	get_tree().create_timer(_stalker.punch_duration + 0.3).timeout.connect(
		func() -> void:
			_stop_test("Dummy died. Stalker moved to a random spot. Press T to run again."),
		CONNECT_ONE_SHOT
	)


# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	print("key: ", OS.get_keycode_string(key.physical_keycode), "  phase: ", Phase.keys()[_phase])
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
		KEY_ESCAPE:
			if _phase == Phase.PLACE_CUBE:
				_cancel_cube_ghost()
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
					_stop_test("Test stopped. Stalker moved to a random spot. Press T to run again.")
				Phase.PLACE_DUMMY:
					_say("Place the Dummy first (E).")
				Phase.PLACE_CUBE:
					_say("Place or cancel the cube first (E / Esc).")
		_:
			return
	get_viewport().set_input_as_handled()


func _confirm_place() -> void:
	match _phase:
		Phase.PLACE_DUMMY:
			if not _dummy_spot_valid():
				_say("Can't place the Dummy here (too close to a cube or the Stalker).")
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
	if _dist_to_cube(_stalker.global_position, p) < STALKER_CLEARANCE:
		return false
	return true


func _dummy_spot_valid() -> bool:
	var p := _subject.global_position
	if _min_dist_to_cubes(p) < DUMMY_CLEARANCE:
		return false
	return _flat_dist(p, _stalker.global_position) >= DUMMY_STALKER_MIN


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
	var text := "Mode: %s\nStalker: %s\nLight: %s%s\nCubes: %d   Navmesh: %s\n%s" % [
		phase_name,
		_stalker.state_name(),
		"ON" if _subject.flashlight_is_on else "OFF",
		dead,
		_cubes.size(),
		nav_state,
		help,
	]
	if _message_time > 0.0:
		text += "\n>> " + _message
	_debug_label.text = text
