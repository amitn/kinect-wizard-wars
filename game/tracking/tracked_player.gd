class_name TrackedPlayer
extends RefCounted
## One tracked person with a persistent id, 33 joints, body root and derived state.
## Game code reads the convenience properties and never touches landmark indices.

const JOINT_NAMES := [
	"nose", "left_eye_inner", "left_eye", "left_eye_outer", "right_eye_inner", "right_eye", "right_eye_outer",
	"left_ear", "right_ear", "mouth_left", "mouth_right",
	"left_shoulder", "right_shoulder", "left_elbow", "right_elbow", "left_wrist", "right_wrist",
	"left_pinky", "right_pinky", "left_index", "right_index", "left_thumb", "right_thumb",
	"left_hip", "right_hip", "left_knee", "right_knee", "left_ankle", "right_ankle",
	"left_heel", "right_heel", "left_foot_index", "right_foot_index",
]

var id: int = 0
var joints: Dictionary = {}          # name -> TrackedJoint
var position := Vector3.ZERO         # body root: hips centre, camera space meters
var velocity := Vector3.ZERO
var tracking_confidence := 0.0
var visible := false
var last_seen := 0.0
var first_seen := 0.0
var standing_height := 0.0           # meters, median of recent head-to-feet readings
var height_samples: Array[float] = []
var is_crouching := false
var is_jumping := false
var arms_up := false
var hands_together := false
var gestures: Dictionary = {}        # gesture name -> time it fired (seconds)

var _filters: Dictionary = {}        # name -> PoseFilter
var _hip_height_history: Array[float] = []


func _init() -> void:
	for n in JOINT_NAMES:
		var j := TrackedJoint.new()
		j.name = n
		joints[n] = j
		_filters[n] = PoseFilter.new()


func joint(n: String) -> TrackedJoint:
	return joints[n]


func filter_for(n: String) -> PoseFilter:
	return _filters[n]


# Convenience accessors. "left"/"right" are the person's own sides.
var head: TrackedJoint:
	get: return joints["nose"]
var left_hand: TrackedJoint:
	get: return joints["left_wrist"]
var right_hand: TrackedJoint:
	get: return joints["right_wrist"]
var left_elbow: TrackedJoint:
	get: return joints["left_elbow"]
var right_elbow: TrackedJoint:
	get: return joints["right_elbow"]
var left_shoulder: TrackedJoint:
	get: return joints["left_shoulder"]
var right_shoulder: TrackedJoint:
	get: return joints["right_shoulder"]
var left_foot: TrackedJoint:
	get: return joints["left_ankle"]
var right_foot: TrackedJoint:
	get: return joints["right_ankle"]


func shoulder_center() -> Vector3:
	return (left_shoulder.position_3d + right_shoulder.position_3d) * 0.5


func has_gesture(gesture: String, within_s: float = 0.15) -> bool:
	return gestures.has(gesture) and Time.get_ticks_msec() / 1000.0 - float(gestures[gesture]) <= within_s
