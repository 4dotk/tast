extends SceneTree
## (Re)bakes res://test/test_room/test_room.navmesh from the test room geometry.
##
## Run with:  godot --headless -s tools/bake_navmesh.gd
##
## Normally you do not need this: test_room/nav_region.gd bakes and caches
## the mesh on first run. Use this tool to force a re-bake after changing
## the room layout (it also clears the cached file first).

const ROOM_PATH := "res://test/test_room/test_room.tscn"
const OUTPUT_PATH := "res://test/test_room/test_room.tres"


func _initialize() -> void:
	var cache_file := FileAccess.open(OUTPUT_PATH, FileAccess.READ)
	if cache_file:
		cache_file.close()
		DirAccess.remove_absolute(OUTPUT_PATH)

	var room_scene: PackedScene = load(ROOM_PATH)
	var room := room_scene.instantiate()
	root.add_child(room)

	var region: NavigationRegion3D = room.get_node(^"Room/Navigation")
	if region.navigation_mesh == null:
		region.navigation_mesh = NavigationMesh.new()
	region.navigation_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	region.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	region.bake_navigation_mesh(false)

	var mesh: NavigationMesh = region.navigation_mesh
	if mesh == null or mesh.get_polygon_count() == 0:
		printerr("bake_navmesh: bake produced no polygons.")
		quit(1)
		return

	var error := ResourceSaver.save(mesh, OUTPUT_PATH)
	if error != OK:
		printerr("bake_navmesh: failed to save (error %d)." % error)
		quit(1)
		return
	print("bake_navmesh: saved %s (%d polygons)." % [OUTPUT_PATH, mesh.get_polygon_count()])
	quit(0)
