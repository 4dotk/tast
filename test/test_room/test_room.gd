extends Node3D
## Player vs monsters test room.
##
## The Dummy is a real, always-controllable player. It is never frozen:
##   W/S - walk forward / back, A/D - turn (Q lock-on makes A/D strafe),
##   F - toggle the flashlight.
##
## Workflow
##   1. PREPARE   N places an enemy: a ghost appears, the arrow keys move it,
##                E spawns it (you keep placing more), Tab switches the type
##                (Stalker / Seeker), Esc cancels. O places obstacle cubes the
##                same way (arrows move the ghost, E places, Esc when done),
##                Backspace removes the last cube.
##   2. T        Start the test: every placed enemy activates and goes after
##               the player.
##   3. T again  Stop: enemies are deactivated and returned to where you
##               placed them. Press T to run again.
##   4. Player dies  the monsters stop, the Dummy respawns at its start
##                 position. Press T to run again.
##
## The monsters' AI is untouched - they are just instanced, placed and
## activated here.

enum Phase { PREPARE, PLACE_ENEMY, PLACE_CUBE, RUNNING, RESETTING }
enum EnemyType { STALKER, SEEKER }

const STALKER_SCENE := preload("res://entities/monsters/stalker/stalker.tscn")
const SEEKER_SCENE := preload("res://entities/monsters/seeker/seeker.tscn")

## Edge length of an obstacle cube (meters).
const CUBE_SIZE := 1.5
## The walkable navmesh reaches +-14.5; keep things inside it.
const NAV_EDGE := 14.5
## Keep the player on the floor.
const FLOOR_EDGE := 14.5
## A monster must stay this far from a cube surface / the player.
const MONSTER_CLEARANCE := 1.0
const DUMMY_MONSTER_MIN := 2.5
## Two monsters keep this center-to-center distance.
const MONSTER_GAP := 2.0
## How long (seconds) after the player dies before the test is reset.
## Keep it a little shorter than the Player's respawn_delay.
const DEATH_RESET_DELAY := 2.0
## Ghost speed while placing (m/s).
const GHOST_SPEED := 7.0

@onready var _debug_label: Label = $Debug/DebugLabel
@onready var _subject: Player = $Player
@onready var _nav: TestRoomNav = $Room/Navigation

var _phase := Phase.PREPARE
var _enemy_type := EnemyType.STALKER
## Placed (but currently inactive) monsters.
var _monsters: Array[Node3D] = []
## instance_id -> the spot the monster was placed at (its home).
var _monster_home: Dictionary = {}
var _cubes: Array[StaticBody3D] = []
var _enemy_ghost: MeshInstance3D
var _cube_ghost: MeshInstance3D
var _ghost_material: StandardMaterial3D
var _cube_material: StandardMaterial3D
var _marker: MeshInstance3D
var _marker_material: StandardMaterial3D
var _last_enemy_pos := Vector3.ZERO
var _last_cube_pos := Vector3.ZERO
var _baking := false
var _message := ""
var _message_time := 0.0


func _ready() -> void:
	_ensure_input_actions()
	_build_materials()
	_build_ghosts()
	_nav.rebake_finished.connect(_on_rebake_finished)
	print("Player vs monsters room.  WASD move | N enemy (arrows, E) | O cube (arrows, E) | Tab type | T start | Esc menu")


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


func _build_ghosts() -> void:
	# Enemy ghost: a translucent capsule roughly body-sized.
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.8
	cap.material = _ghost_material
	_enemy_ghost = MeshInstance3D.new()
	_enemy_ghost.mesh = cap
	_enemy_ghost.visible = false
	_enemy_ghost.position = Vector3(0.0, cap.height * 0.5, 0.0)
	add_child(_enemy_ghost)

	# Cube ghost.
	var box := BoxMesh.new()
	box.size = Vector3.ONE * CUBE_SIZE
	box.material = _ghost_material
	_cube_ghost = MeshInstance3D.new()
	_cube_ghost.mesh = box
	_cube_ghost.visible = false
	add_child(_cube_ghost)

	# Validity marker disc under the active ghost.
	var disc := CylinderMesh.new()
	disc.top_radius = 0.8
	disc.bottom_radius = 0.8
	disc.height = 0.02
	disc.material = _marker_material
	_marker = MeshInstance3D.new()
	_marker.mesh = disc
	_marker.visible = false
	add_child(_marker)


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


# ------------------------------------------------------------------- enemies

func _enemy_name() -> String:
	return "Stalker" if _enemy_type == EnemyType.STALKER else "Seeker"


func _begin_enemy_ghost() -> void:
	_enemy_ghost.visible = true
	_enemy_ghost.position = Vector3(_last_enemy_pos.x, _enemy_ghost.position.y, _last_enemy_pos.z)
	_phase = Phase.PLACE_ENEMY
	_say("Placing a %s. Arrows move, E spawn, Esc cancel." % _enemy_name())


func _cycle_enemy_type() -> void:
	match _phase:
		Phase.RUNNING, Phase.RESETTING:
			_say("Stop the test first (T) to change the enemy type.")
			return
	_enemy_type = EnemyType.SEEKER if _enemy_type == EnemyType.STALKER else EnemyType.STALKER
	_say("Placing a %s." % _enemy_name())


func _spawn_enemy_at(pos: Vector3) -> void:
	var monster: Node3D
	if _enemy_type == EnemyType.STALKER:
		var st := STALKER_SCENE.instantiate() as Stalker
		st.visible = false
		add_child(st)
		st.relocate(pos)
		st.visible = true
		st.player_killed.connect(_on_player_killed.bind(st))
		monster = st
	else:
		var sk := SEEKER_SCENE.instantiate() as Seeker
		sk.visible = false
		add_child(sk)
		sk.show_debug_label = true
		sk.place_at(pos)
		sk.visible = true
		sk.killed_holder.connect(_on_seeker_killed_holder)
		sk.killed_monster.connect(_on_seeker_killed_monster)
		sk.destroyed_obstacle.connect(_on_seeker_destroyed_obstacle)
		monster = sk
	_monsters.append(monster)
	_monster_home[monster.get_instance_id()] = pos


# --------------------------------------------------------------- start / stop

func _start_test() -> void:
	if _subject.is_in_group("dead"):
		_say("The player is respawning, wait a moment.")
		return
	if _baking:
		_say("The navmesh is still baking, wait a moment.")
		return
	if _monsters.is_empty():
		_say("Place an enemy first (N).")
		return
	_phase = Phase.RUNNING
	for m in _monsters:
		_activate(m)
	_say("Test running with %d enem%s." % [_monsters.size(), "y" if _monsters.size() == 1 else "ies"])


func _stop_test(message: String) -> void:
	for m in _monsters:
		_return_monster_home(m)
	_phase = Phase.PREPARE
	_say(message)


func _activate(m: Node3D) -> void:
	if m is Stalker:
		(m as Stalker).activate()
	elif m is Seeker:
		(m as Seeker).activate()


func _return_monster_home(m: Node3D) -> void:
	if not is_instance_valid(m):
		return
	var pos: Vector3 = _monster_home.get(m.get_instance_id(), m.global_position)
	if m is Stalker:
		(m as Stalker).relocate(pos)
	elif m is Seeker:
		(m as Seeker).place_at(pos)
		(m as Seeker).deactivate()


# --------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey

	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_TAB:
		_cycle_enemy_type()
		get_viewport().set_input_as_handled()
		return

	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		if _phase == Phase.PLACE_ENEMY:
			_cancel_enemy_ghost()
		elif _phase == Phase.PLACE_CUBE:
			_cancel_cube_ghost()
		else:
			get_tree().change_scene_to_file("res://ui/menus/main_menu/main_menu.tscn")
		get_viewport().set_input_as_handled()
		return

	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_N:
			_on_place_enemy_key()
		KEY_O:
			_on_add_cube_key()
		KEY_E:
			_on_confirm_key()
		KEY_BACKSPACE:
			_on_remove_cube_key()
		KEY_T:
			_on_start_stop_key()
		_:
			return
	get_viewport().set_input_as_handled()


func _on_place_enemy_key() -> void:
	match _phase:
		Phase.PREPARE:
			_begin_enemy_ghost()
		Phase.PLACE_ENEMY:
			_say("Already placing an enemy: E to spawn, Esc to cancel.")
		Phase.PLACE_CUBE:
			_say("Finish the cube first (E / Esc).")
		Phase.RUNNING, Phase.RESETTING:
			_say("Stop the test first (T).")


func _on_add_cube_key() -> void:
	match _phase:
		Phase.PREPARE:
			_begin_cube_ghost()
		Phase.PLACE_CUBE:
			_say("Already placing a cube: E to place, Esc when done.")
		Phase.PLACE_ENEMY:
			_say("Finish the enemy first (E / Esc).")
		Phase.RUNNING, Phase.RESETTING:
			_say("Stop the test first (T).")


func _on_confirm_key() -> void:
	match _phase:
		Phase.PLACE_ENEMY:
			_confirm_enemy_place()
		Phase.PLACE_CUBE:
			_confirm_cube_place()
		Phase.PREPARE:
			_say("Nothing to place. N places an enemy, O adds a cube.")
		Phase.RUNNING, Phase.RESETTING:
			_say("The test is running. T stops it.")


func _on_remove_cube_key() -> void:
	if _phase == Phase.PREPARE:
		_remove_last_cube()
	else:
		_say("Backspace removes the last cube (in PREPARE).")


func _on_start_stop_key() -> void:
	match _phase:
		Phase.PREPARE:
			_start_test()
		Phase.RUNNING:
			_stop_test("Test stopped. Enemies wait where you placed them. Press T to run again.")
		Phase.PLACE_ENEMY, Phase.PLACE_CUBE:
			_say("Finish or cancel the placement first (E / Esc).")
		Phase.RESETTING:
			_say("Waiting for the player to respawn.")


func _cancel_enemy_ghost() -> void:
	if _enemy_ghost:
		_last_enemy_pos = Vector3(_enemy_ghost.position.x, 0.0, _enemy_ghost.position.z)
		_enemy_ghost.visible = false
	_phase = Phase.PREPARE


func _cancel_cube_ghost() -> void:
	if _cube_ghost:
		_last_cube_pos = _cube_ghost.position
		_cube_ghost.visible = false
	_phase = Phase.PREPARE


# ------------------------------------------------------------------- enemies

func _confirm_enemy_place() -> void:
	if not _enemy_spot_valid():
		_say("Can't place the enemy here (too close to the player, another enemy or a cube).")
		return
	var pos := Vector3(_enemy_ghost.position.x, 0.0, _enemy_ghost.position.z)
	_spawn_enemy_at(pos)
	_last_enemy_pos = pos
	_say("Placed a %s. E places more, Esc when done, then T starts the test." % _enemy_name())


# ------------------------------------------------------------------- cubes

func _begin_cube_ghost() -> void:
	_cube_ghost.visible = true
	_cube_ghost.position = Vector3(_last_cube_pos.x, CUBE_SIZE * 0.5, _last_cube_pos.z)
	_phase = Phase.PLACE_CUBE
	_say("Placing a cube. Arrows move, E place, Esc when done.")


func _confirm_cube_place() -> void:
	if not _cube_spot_valid():
		_say("Can't place the cube here (overlap or too close).")
		return
	_place_cube()


func _place_cube() -> void:
	var pos := _cube_ghost.position
	_last_cube_pos = pos
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
	_nav.add_child(body)
	body.global_position = pos
	_cubes.append(body)
	_request_rebake()
	_say("Cube placed (%d total). E places more, Esc when done." % _cubes.size())


func _remove_last_cube() -> void:
	if _cubes.is_empty():
		_say("No cubes to remove.")
		return
	var cube: StaticBody3D = _cubes.pop_back()
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


func _enemy_spot_valid() -> bool:
	if _enemy_ghost == null:
		return false
	var p := Vector3(_enemy_ghost.position.x, 0.0, _enemy_ghost.position.z)
	if absf(p.x) > NAV_EDGE or absf(p.z) > NAV_EDGE:
		return false
	if _flat_dist(p, _subject.global_position) < DUMMY_MONSTER_MIN:
		return false
	for m in _monsters:
		if _flat_dist(p, m.global_position) < MONSTER_GAP:
			return false
	if _min_dist_to_cubes(p) < MONSTER_CLEARANCE:
		return false
	return true


func _cube_spot_valid() -> bool:
	if _cube_ghost == null:
		return false
	var p := _cube_ghost.position
	for cube in _cubes:
		var c: Vector3 = cube.global_position
		if absf(p.x - c.x) < CUBE_SIZE and absf(p.z - c.z) < CUBE_SIZE:
			return false
	if _dist_to_cube(_subject.global_position, p) < MONSTER_CLEARANCE:
		return false
	for m in _monsters:
		if _dist_to_cube(m.global_position, p) < MONSTER_CLEARANCE:
			return false
	return true


# ------------------------------------------------------------- monster events

func _on_player_killed(_victim: Node3D, _stalker: Stalker) -> void:
	_begin_reset(DEATH_RESET_DELAY, "The player was killed. Press T to run again.")


func _on_seeker_killed_holder(_source: Node3D) -> void:
	_begin_reset(DEATH_RESET_DELAY, "The Seeker took the torch and the player died. Press T to run again.")


func _on_seeker_killed_monster(monster: Node3D) -> void:
	if monster in _monsters:
		_monsters.erase(monster)
		_monster_home.erase(monster.get_instance_id())
	monster.queue_free()
	_say("The Seeker killed a Stalker.")


func _on_seeker_destroyed_obstacle(obstacle: Node3D) -> void:
	_cubes.erase(obstacle)
	_request_rebake()
	_say("The Seeker smashed a cube (%d left)." % _cubes.size())


func _begin_reset(delay: float, message: String) -> void:
	if _phase != Phase.RUNNING:
		return
	_phase = Phase.RESETTING
	get_tree().create_timer(delay).timeout.connect(
		func() -> void:
			_stop_test(message),
		CONNECT_ONE_SHOT
	)


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	_clamp_subject()
	# While placing, E / Q / F belong to the placement, not the Player (E would
	# otherwise also drop the flashlight).
	_subject.set_process_unhandled_input(
		_phase != Phase.PLACE_ENEMY and _phase != Phase.PLACE_CUBE
	)
	match _phase:
		Phase.PLACE_ENEMY:
			if _enemy_ghost:
				_move_enemy_ghost(delta)
		Phase.PLACE_CUBE:
			if _cube_ghost:
				_move_cube_ghost(delta)
	_update_ghost_marker()
	_message_time = maxf(_message_time - delta, 0.0)
	_update_label()


## Keep the player on the floor in every phase.
func _clamp_subject() -> void:
	if _subject.is_in_group("dead"):
		return
	var p: Vector3 = _subject.global_position
	p.x = clampf(p.x, -FLOOR_EDGE, FLOOR_EDGE)
	p.z = clampf(p.z, -FLOOR_EDGE, FLOOR_EDGE)
	_subject.global_position = p


func _move_enemy_ghost(delta: float) -> void:
	var input := _arrow_vector()
	if input.length() > 0.01:
		var step := _camera_world_vector(input) * GHOST_SPEED * delta
		var q := _enemy_ghost.position + step
		q.x = clampf(q.x, -NAV_EDGE, NAV_EDGE)
		q.z = clampf(q.z, -NAV_EDGE, NAV_EDGE)
		_enemy_ghost.position = q


func _move_cube_ghost(delta: float) -> void:
	var input := _arrow_vector()
	var step := _camera_world_vector(input) * GHOST_SPEED * delta
	var half := CUBE_SIZE * 0.5
	var limit := NAV_EDGE - half
	var q := _cube_ghost.position + step
	q.x = clampf(q.x, -limit, limit)
	q.z = clampf(q.z, -limit, limit)
	q.y = half
	_cube_ghost.position = q


func _arrow_vector() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT):
		v.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN):
		v.y += 1.0
	return v


## A floor-space direction for an input vector, relative to the fixed camera.
func _camera_world_vector(input: Vector2) -> Vector3:
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

func _update_ghost_marker() -> void:
	var active: MeshInstance3D = null
	var valid := false
	match _phase:
		Phase.PLACE_ENEMY:
			active = _enemy_ghost
			valid = _enemy_spot_valid()
		Phase.PLACE_CUBE:
			active = _cube_ghost
			valid = _cube_spot_valid()
	if active == null:
		_marker.visible = false
		return
	_marker.visible = true
	_marker.global_position = Vector3(active.position.x, 0.02, active.position.z)
	_marker_material.albedo_color = Color(0.2, 1.0, 0.3, 0.5) if valid else Color(1.0, 0.15, 0.15, 0.6)


func _say(text: String) -> void:
	_message = text
	_message_time = 5.0
	print(text)


func _update_label() -> void:
	var phase_name := ""
	var help := ""
	match _phase:
		Phase.PREPARE:
			phase_name = "PREPARE"
			help = "WASD move  |  N enemy  |  O cube  |  Tab type  |  T start"
		Phase.PLACE_ENEMY:
			phase_name = "PLACING %s" % _enemy_name().to_upper()
			help = "Arrows move  |  E spawn  |  Tab type  |  Esc cancel"
		Phase.PLACE_CUBE:
			phase_name = "PLACING CUBE"
			help = "Arrows move  |  E place  |  Esc done"
		Phase.RUNNING:
			phase_name = "RUNNING"
			help = "WASD move/aim  |  Q lock-on  |  F light  |  T stop"
		Phase.RESETTING:
			phase_name = "RESETTING..."
			help = ""

	var monster_lines := PackedStringArray()
	if _monsters.is_empty():
		monster_lines.append("No enemies placed (press N).")
	else:
		for m in _monsters:
			var line := "Enemy"
			if m is Stalker:
				line = "Stalker: " + (m as Stalker).state_name()
			elif m is Seeker:
				line = "Seeker: " + (m as Seeker).state_name()
			monster_lines.append(line)

	var nav_state := "baking..." if _baking else "ready"
	var dead := " (dead)" if _subject.is_in_group("dead") else ""
	var text := "Room: %s\n%s\nLight: %s%s  [F]\nCubes: %d   Navmesh: %s\n%s  [Esc] menu" % [
		phase_name,
		"\n".join(monster_lines),
		"ON" if _subject.is_flashlight_on() else "OFF",
		dead,
		_cubes.size(),
		nav_state,
		help,
	]
	if _message_time > 0.0:
		text += "\n>> " + _message
	_debug_label.text = text
