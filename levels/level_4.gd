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

var _scare_done := false
var _seeker_home := Transform3D.IDENTITY


func _ready() -> void:
	# Children run _ready() before their parent, so Player, Seeker and
	# Flashlight are already fully set up here.
	_seeker_home = seeker.global_transform
	_lay_torch_on_floor()

	scare_trigger.body_entered.connect(_on_scare_trigger_body_entered)
	player.respawned.connect(_on_player_respawned)


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
	)
	var torch_pos := torch_spawn.global_position + Vector3.UP * torch.dropped_height
	torch.global_transform = Transform3D(torch_basis, torch_pos)
	torch.set_held(false)


func _on_scare_trigger_body_entered(body: Node3D) -> void:
	if _scare_done or not body.is_in_group(&"player"):
		return
	_scare_done = true
	# Physics callbacks can't change monitoring directly: defer it.
	scare_trigger.set_deferred(&"monitoring", false)

	if scare_delay > 0.0:
		await get_tree().create_timer(scare_delay).timeout

	if scare_sting != null:
		scare_sting.play()
	# From here the Seeker's own AI takes over: it goes for any lit light
	# it can see within its attraction radius (the held torch = the player).
	seeker.activate()


## The Player respawns holding a torch (player.gd). In this level she must
## not have one, so reset the whole scare: torch back on the floor, Seeker
## back home, trigger armed again.
func _on_player_respawned() -> void:
	_lay_torch_on_floor()
	seeker.deactivate()
	seeker.global_transform = _seeker_home
	seeker.place_at(_seeker_home.origin)
	_scare_done = false
	scare_trigger.monitoring = true
