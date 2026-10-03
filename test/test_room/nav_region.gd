class_name TestRoomNav
extends NavigationRegion3D
## Navigation source for the test room.
##
## The walkable mesh is derived from the room geometry: every StaticBody3D /
## MeshInstance3D that is a child of this node is baked into the navmesh
## (upward-facing surfaces become walkable, walls carve it out).
##
## The result of the first bake is cached to a .navmesh file so later runs
## skip baking entirely. Delete res://test/test_room/test_room.navmesh (or run
## tools/bake_navmesh.gd) to re-bake after moving room geometry.

const BAKED_NAVMESH_PATH := "res://test/test_room/test_room.tres"

## Bake on the main thread at startup instead of on a background thread.
## A prototype scene starts fast either way; sync keeps the tool scripts
## deterministic.
@export var bake_synchronously := true

## Emitted when a rebake() requested at runtime has finished.
signal rebake_finished

var _rebake_pending := false


func _ready() -> void:
	if _has_baked_mesh():
		return
	if ResourceLoader.exists(BAKED_NAVMESH_PATH):
		navigation_mesh = load(BAKED_NAVMESH_PATH)
		return
	if navigation_mesh == null:
		navigation_mesh = NavigationMesh.new()
	# Bake from collision shapes only: cheap, deterministic, and it skips the
	# expensive path of pulling visual meshes back from the GPU.
	navigation_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	bake_navigation_mesh(not bake_synchronously)
	if bake_synchronously:
		_cache_baked_mesh()
	else:
		bake_finished.connect(_cache_baked_mesh, CONNECT_ONE_SHOT)


func _has_baked_mesh() -> bool:
	return navigation_mesh != null and navigation_mesh.get_polygon_count() > 0


func _cache_baked_mesh() -> void:
	if not _has_baked_mesh():
		push_warning("Test room: navigation bake produced no polygons.")
		return
	var error := ResourceSaver.save(navigation_mesh, BAKED_NAVMESH_PATH)
	if error == OK:
		print("Test room: navigation mesh baked and cached to ", BAKED_NAVMESH_PATH)
	else:
		push_warning("Test room: failed to cache navigation mesh (error %d)." % error)


## Re-bake the navmesh at runtime (e.g. after obstacles were added/removed
## under this node). Runs on a background thread; emits rebake_finished.
## The result is NOT written to the cached .tres, so the cache stays the empty room.
func rebake() -> void:
	if is_baking():
		_rebake_pending = true
		return
	if navigation_mesh == null:
		navigation_mesh = NavigationMesh.new()
	navigation_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	bake_finished.connect(_on_rebake_finished, CONNECT_ONE_SHOT)
	bake_navigation_mesh(true)


func _on_rebake_finished() -> void:
	if _rebake_pending:
		_rebake_pending = false
		rebake()
		return
	rebake_finished.emit()
