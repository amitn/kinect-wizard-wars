class_name TrackedJoint
extends RefCounted
## One body joint. Coordinate spaces are kept apart on purpose:
##   normalized_position  0..1 in the color image
##   image_position       pixels in the color image
##   position_3d          camera space, meters: +x right, +y up, +z away from the camera
## `depth_inferred` is true when the depth sensor had no reading and the value was
## carried over from a recent frame.

var name: String = ""
var normalized_position := Vector2.ZERO
var image_position := Vector2.ZERO
var position_3d := Vector3.ZERO
var raw_position := Vector3.ZERO  # unfiltered camera-space position
var velocity := Vector3.ZERO      # meters per second, filtered
var visibility := 0.0
var confidence := 0.0
var valid := false
var depth_inferred := false
