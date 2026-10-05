extends Node3D
# PSX pack demo: WASD + mouse to walk, F to swap Normal/Nightmare, Esc frees the mouse.
# "-- --autotest" saves screenshots to shots/ and quits.

var normal: Node3D
var horror: Node3D
var player: CharacterBody3D
var cam: Camera3D
var hud: Label
var flicker: Array[Light3D] = []
var in_horror := false
var yaw := 0.0
var pitch := 0.0
var cfg := {}

func _ready() -> void:
	cfg = JSON.parse_string(FileAccess.get_file_as_string("res://start.json"))
	for f in DirAccess.get_files_at("res://rooms"):
		if f.ends_with("_Normal.glb"):
			normal = load("res://rooms/" + f).instantiate()
		elif f.ends_with("_Horror.glb"):
			horror = load("res://rooms/" + f).instantiate()
	add_child(normal)
	add_child(horror)
	for room in [normal, horror]:
		_prep(room)
	horror.visible = false
	_set_collision(horror, false)
	for n in cfg.get("flicker", []):
		var l := horror.find_child(n, true, false) as Light3D
		if l:
			flicker.append(l)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.02, 0.02, 0.03)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.25, 0.27, 0.3)
	env.environment.ambient_light_energy = float(cfg.get("ambient", 0.4))
	add_child(env)

	player = CharacterBody3D.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.25
	cap.height = 1.7
	col.shape = cap
	col.position.y = 0.85
	player.add_child(col)
	cam = Camera3D.new()
	cam.position.y = 1.6
	cam.fov = 70
	player.add_child(cam)
	add_child(player)
	var s: Array = cfg["start"]
	player.position = Vector3(s[0], s[1], s[2])
	yaw = float(cfg.get("yaw", 0.0))
	player.rotation.y = yaw

	hud = Label.new()
	hud.position = Vector2(12, 8)
	hud.add_theme_font_size_override("font_size", 22)
	add_child(hud)
	_update_hud()
	if "--autotest" in OS.get_cmdline_user_args():
		_autotest()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _prep(room: Node) -> void:
	for n in room.find_children("*", "", true, false):
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(i)
				if m is BaseMaterial3D:
					(m as BaseMaterial3D).texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			var nm := String(mi.name)
			if not (nm.begins_with("Horror_") or nm.begins_with("CeilingLight") or nm.begins_with("Backdrop") or nm.begins_with("Decal")):
				mi.create_trimesh_collision()
		elif n is Light3D:
			(n as Light3D).shadow_enabled = true

func _set_collision(room: Node, on: bool) -> void:
	for b in room.find_children("*", "StaticBody3D", true, false):
		(b as StaticBody3D).process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
		for c in b.get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = not on

func _swap() -> void:
	in_horror = not in_horror
	normal.visible = not in_horror
	horror.visible = in_horror
	_set_collision(normal, not in_horror)
	_set_collision(horror, in_horror)
	_update_hud()

func _update_hud() -> void:
	hud.text = "%s   |   WASD move, mouse look, F swap, Esc free mouse" % ("NIGHTMARE" if in_horror else "NORMAL")

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= e.relative.x * 0.003
		pitch = clamp(pitch - e.relative.y * 0.003, -1.4, 1.4)
		player.rotation.y = yaw
		cam.rotation.x = pitch
	elif e is InputEventKey and e.pressed and not e.echo:
		if e.physical_keycode == KEY_F:
			_swap()
		elif e.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): dir.z -= 1
	if Input.is_physical_key_pressed(KEY_S): dir.z += 1
	if Input.is_physical_key_pressed(KEY_A): dir.x -= 1
	if Input.is_physical_key_pressed(KEY_D): dir.x += 1
	dir = (player.transform.basis * dir).normalized() * 3.0
	player.velocity.x = dir.x
	player.velocity.z = dir.z
	player.velocity.y = 0.0 if player.is_on_floor() else player.velocity.y - 9.8 * delta
	player.move_and_slide()

func _process(_delta: float) -> void:
	if in_horror:
		for l in flicker:
			l.visible = randf() > 0.12

func _autotest() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	var i := 0
	for v in cfg.get("views", []):
		player.position = Vector3(v[0], v[1], v[2])
		player.rotation.y = v[3]
		cam.rotation.x = v[4]
		for mode in ["normal", "horror"]:
			if (mode == "horror") != in_horror:
				_swap()
			for l in flicker:
				l.visible = true
			for k in 6:
				await get_tree().physics_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://shots/view%d_%s.png" % [i, mode])
		i += 1
	var nb := normal.find_children("*", "StaticBody3D", true, false).size()
	print("AUTOTEST DONE bodies=%d floor=%s" % [nb, player.is_on_floor()])
	get_tree().quit()
