extends Node

func _ready() -> void:
	# RAD_TO_DEG and HALF_PI are not GDScript constants. Use the functions / TAU.
	print(rad_to_deg(PI), " ", PI / 2.0, " ", PI)
	# The class is PhysicsRayQueryParameters3D (no IntersectionRayQueryParameters3D in 4.x).
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3(1, 0, 0))
	print(q)
