class_name ShoulderCamera
extends Node3D
## Over-the-shoulder test camera. Add it as a child of the Player.
## The Player drives it for free: the camera turns with her (tank controls).
## A SpringArm3D pulls the camera in whenever a wall is behind her, so the
## view never ends up outside the room.

## Distance behind the player (local units; the Player is scaled 0.8).
@export_range(0.5, 6.0, 0.1) var arm_length := 2.6
## Sideways offset. Positive = over her right shoulder, negative = left.
@export_range(-1.5, 1.5, 0.05) var shoulder_offset := 0.55
## Height of the camera pivot above her feet.
@export_range(0.5, 3.0, 0.05) var height := 1.7
## Look-down angle. Negative looks down at her.
@export_range(-60.0, 30.0, 1.0) var pitch_degrees := -12.0
## Make this the active camera as soon as it enters the scene.
@export var make_current := true

@onready var _arm: SpringArm3D = $SpringArm3D
@onready var _camera: Camera3D = $SpringArm3D/Camera3D


func _ready() -> void:
	position = Vector3(shoulder_offset, height, 0.0)
	_arm.spring_length = arm_length
	_arm.rotation_degrees.x = pitch_degrees
	# The arm must not collide with the body it is attached to.
	var body := get_parent() as CollisionObject3D
	if body != null:
		_arm.add_excluded_object(body.get_rid())
	if make_current:
		_camera.make_current()
