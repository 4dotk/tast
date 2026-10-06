class_name Level4
extends Node3D
## Level 4
##   1) ENTRY       - narrow room. The torch lies on the floor at TorchSpawn.
##   2) SEEKER ROOM - the Seeker waits, inactive. Crossing ScareTrigger springs it.
##
## This script only wires scenes together. Player / Seeker / Flashlight keep
## all of their own behaviour; the level just tells them *when*.

## The Player node placed in this level (instance of player.tscn).
@export var player: Player
## The Seeker placed in the seeker room (instance of seeker.tscn).
@export var seeker: Seeker

@export_group("Obstacle")
## The destroyable shelf blocking the seeker room's exit door. When the Player
## respawns, a fresh copy is put back if the Seeker smashed it.
@export var obstacle: Node3D

@export_group("Entry")
## Marker3D on the entry floor. Its -Z axis (blue arrow in the editor) is the
## direction the beam points while the torch lies there.
@export var torch_spawn: Marker3D

@export_group("Jumpscare")
## Area3D just inside the seeker room's doorway. Mask must include the player's layer.
@export var scare_trigger: Area3D
## Optional stinger played the moment the Seeker is released.
@export var scare_sting: AudioStreamPlayer
## Pause (seconds) between crossing the trigger and the Seeker waking up.
@export_range(0.0, 3.0, 0.05) var scare_delay := 0.0

@export_group("Stalkers")
## Area3D in the corridor just past the Seeker room's exit door. Until the
## player crosses it the Stalkers stay dormant; after that they can see
## (see Stalker.require_line_of_sight: walls block their sight).
@export var stalker_trigger: Area3D

## Area3D far down the hallway. Crossing it (after the Stalkers were
## released) kills the torch: light off, cannot be switched on again.
@export var torch_death_trigger: Area3D

@export_group("Navigation")
## The Seeker needs a navigation mesh to chase the player.
@export var nav_region: NavigationRegion3D
## Bake that mesh from the level's colliders when the level starts (prototype
## shortcut). Once you bake it in the editor, switch this off.
@export var bake_navigation_on_start := true

var _obstacle_template: Node3D
var _obstacle_parent: Node
var _obstacle_now: Node3D
var _scare_done := false
var _stalkers_done := false
var _torch_dead_done := false
var _seeker_home := Transform3D.IDENTITY


func _ready() -> void:
	# Children run _ready() before their parent, so Player, Seeker and
	# Flashlight are already fully set up here.
	_seeker_home = seeker.global_transform
	if obstacle != null:
		_obstacle_parent = obstacle.get_parent()
		_obstacle_now = obstacle
		_obstacle_template = obstacle.duplicate()  # pristine copy, kept out of the tree
	_lay_torch_on_floor()

	scare_trigger.body_entered.connect(_on_scare_trigger_body_entered)
	player.respawned.connect(_on_player_respawned)
	if stalker_trigger != null:
		stalker_trigger.body_entered.connect(_on_stalker_trigger_body_entered)
	if torch_death_trigger != null:
		torch_death_trigger.body_entered.connect(_on_torch_death_trigger_body_entered)

	if bake_navigation_on_start and nav_region != null:
		_bake_navigation()


func _bake_navigation() -> void:
	# Synchronous on purpose: the threaded bake did not update the navigation
	# server in testing (Godot 4.7), so the Seeker found no path. A level this
	# size bakes in a fraction of a second while it loads.
	nav_region.bake_navigation_mesh(false)
	var polygons := nav_region.navigation_mesh.get_polygon_count()
	print("[Level4] navigation baked: %d polygons" % polygons)
	if polygons == 0:
		push_warning("Level4: the navigation mesh is empty - the Seeker cannot move. "
			+ "Check that the floor has a collider.")


## The Player scene spawns holding its torch. Put it on the entry floor
## instead, so the player has to walk up and pick it up (E).
## The very same Flashlight instance is reused, so the Player's own
## pick-up / drop / animation code keeps working untouched.
func _lay_torch_on_floor() -> void:
	var torch := player.get_flashlight()
	if torch == null or torch_spawn == null:
		push_warning("Level4: no torch or no TorchSpawn marker, leaving the torch in hand.")
		return

	if torch.get_parent() != self:
		torch.reparent(self, false)
	# Same pose the Player uses when it places the torch (see _drop_flashlight).
	var torch_basis := (
		torch_spawn.global_basis.orthonormalized()
		* Basis(Vector3.UP, PI * 0.5)
		* Basis(Vector3.RIGHT, deg_to_rad(player.dropped_roll_degrees))
	).scaled(player.global_basis.get_scale()) # same 0.8 scale as when the Player drops it
	var torch_pos := torch_spawn.global_position + Vector3.UP * torch.dropped_height
	torch.global_transform = Transform3D(torch_basis, torch_pos)
	torch.set_held(false)


func _on_scare_trigger_body_entered(body: Node3D) -> void:
	if _scare_done or not body.is_in_group(&"player"):
		return
	_scare_done = true
	# Physics callbacks can't change monitoring directly: defer it.
	scare_trigger.set_deferred(&"monitoring", false)
	print("[Level4] scare triggered")

	if scare_delay > 0.0:
		await get_tree().create_timer(scare_delay).timeout

	if scare_sting != null:
		scare_sting.play()
	# From here the Seeker's own AI takes over: it goes for any lit light
	# it can see within its attraction radius (the held torch = the player).
	seeker.activate()


func _on_stalker_trigger_body_entered(body: Node3D) -> void:
	if _stalkers_done or not body.is_in_group(&"player"):
		return
	_stalkers_done = true
	stalker_trigger.set_deferred(&"monitoring", false)
	print("[Level4] stalkers released")
	for node in get_tree().get_nodes_in_group(&"stalker"):
		if node is Stalker and is_ancestor_of(node):
			(node as Stalker).activate()


func _on_torch_death_trigger_body_entered(body: Node3D) -> void:
	if _torch_dead_done or not _stalkers_done or not body.is_in_group(&"player"):
		return
	_torch_dead_done = true
	torch_death_trigger.set_deferred(&"monitoring", false)
	var torch := player.get_flashlight()
	if torch != null:
		torch.break_light()
	print("[Level4] torch died")


## The Player respawns holding a torch (player.gd). In this level she must
## not have one, so reset the whole scare: torch back on the floor, Seeker
## back home, trigger armed again.
func _exit_tree() -> void:
	if is_instance_valid(_obstacle_template):
		_obstacle_template.free()


## Puts the shelf back if it was smashed.
func _restore_obstacle() -> void:
	if _obstacle_template == null:
		return
	if is_instance_valid(_obstacle_now) and _obstacle_now.is_inside_tree():
		return
	_obstacle_now = _obstacle_template.duplicate()
	_obstacle_parent.add_child(_obstacle_now)


func _on_player_respawned() -> void:
	var torch := player.get_flashlight()
	if torch != null:
		torch.repair()
		torch.set_light_on(true)
	_lay_torch_on_floor()
	seeker.deactivate()
	_restore_obstacle()
	seeker.global_transform = _seeker_home
	seeker.place_at(_seeker_home.origin)
	# Stalkers go dormant and back to their start; the line re-arms below.
	for node in get_tree().get_nodes_in_group(&"stalker"):
		if node is Stalker and is_ancestor_of(node):
			(node as Stalker).deactivate()
	# Re-arm only after the physics server has processed her teleport back to
	# the entrance. On the same frame the trigger still "sees" her where she
	# died and would fire the scare again.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_scare_done = false
	scare_trigger.monitoring = true
	_stalkers_done = false
	_torch_dead_done = false
	if torch_death_trigger != null:
		torch_death_trigger.monitoring = true
	if stalker_trigger != null:
		stalker_trigger.monitoring = true
