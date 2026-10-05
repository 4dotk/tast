extends SceneTree
## Captures the running test room to a PNG so rendering can be verified.
##
## Run with:  godot --path . -s tools/screenshot.gd

const FRAMES := 120
const OUTPUT := "user://screenshot.png"

var _frames := 0


func _initialize() -> void:
	var room := (load("res://test/test_room/test_room.tscn") as PackedScene).instantiate()
	root.add_child(room)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= FRAMES:
		var image := root.get_viewport().get_texture().get_image()
		if image == null:
			printerr("screenshot: could not read the viewport image.")
		else:
			image.save_png(OUTPUT)
			print("screenshot saved to ", OUTPUT)
		quit()
		return true
	return false
