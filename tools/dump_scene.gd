extends SceneTree

func _init() -> void:
	_dump_file("res://assets/temp/Mannequin.fbx", "MANNEQUIN")
	_dump_file("res://assets/temp/Dummy.fbx", "DUMMY")
	quit()

func _dump_file(path: String, label: String) -> void:
	var res := load(path)
	print("\n===== ", label, " =====")
	if res is PackedScene:
		_dump((res as PackedScene).instantiate())
	else:
		print("Unexpected resource: ", res)

func _dump(root: Node) -> void:
	_print_node(root, 0)

func _print_node(n: Node, depth: int) -> void:
	var prefix := "\t".repeat(depth)
	print(prefix + n.name + " [" + n.get_class() + "]")
	if n is AnimationPlayer:
		var ap := n as AnimationPlayer
		var names := ap.get_animation_list()
		for name in names:
			var anim := ap.get_animation(name)
			print(prefix + "\tAnim: '", name, "' len=", str(round(anim.length * 10.0) / 10.0), "s")
	if n is Skeleton3D:
		print(prefix + "\tbones: ", str((n as Skeleton3D).get_bone_count()))
	for c in n.get_children():
		_print_node(c, depth + 1)
