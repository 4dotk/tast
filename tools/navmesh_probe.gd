extends SceneTree
## Temporary probe: verify navmesh bake + serialization. Delete me.

func _initialize() -> void:
	var room := (load("res://test/test_room/test_room.tscn") as PackedScene).instantiate()
	root.add_child(room)
	var region := room.get_node(^"Room/Navigation")
	region.navigation_mesh = NavigationMesh.new()
	region.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	region.bake_navigation_mesh(false)
	var mesh: NavigationMesh = region.navigation_mesh
	print("polys after bake: ", mesh.get_polygon_count())
	var e1 := ResourceSaver.save(mesh, "user://out.navmesh")
	var e2 := ResourceSaver.save(mesh, "user://out.tres")
	print("save .navmesh err=", e1, " save .tres err=", e2)
	quit()
