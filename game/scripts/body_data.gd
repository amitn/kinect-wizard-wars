class_name BodyData
extends RefCounted
## One tracked person as reported by the Kinect bridge.
## Joints are in Kinect camera space: meters, +y up, +z away from the sensor.

const JOINT_NAMES := [
	"SpineBase", "SpineMid", "Neck", "Head",
	"ShoulderLeft", "ElbowLeft", "WristLeft", "HandLeft",
	"ShoulderRight", "ElbowRight", "WristRight", "HandRight",
	"HipLeft", "KneeLeft", "AnkleLeft", "FootLeft",
	"HipRight", "KneeRight", "AnkleRight", "FootRight",
	"SpineShoulder", "HandTipLeft", "ThumbLeft", "HandTipRight", "ThumbRight",
]

const BONES := [
	["Head", "Neck"], ["Neck", "SpineShoulder"], ["SpineShoulder", "SpineMid"], ["SpineMid", "SpineBase"],
	["SpineShoulder", "ShoulderLeft"], ["ShoulderLeft", "ElbowLeft"], ["ElbowLeft", "WristLeft"],
	["WristLeft", "HandLeft"], ["HandLeft", "HandTipLeft"], ["WristLeft", "ThumbLeft"],
	["SpineShoulder", "ShoulderRight"], ["ShoulderRight", "ElbowRight"], ["ElbowRight", "WristRight"],
	["WristRight", "HandRight"], ["HandRight", "HandTipRight"], ["WristRight", "ThumbRight"],
	["SpineBase", "HipLeft"], ["HipLeft", "KneeLeft"], ["KneeLeft", "AnkleLeft"], ["AnkleLeft", "FootLeft"],
	["SpineBase", "HipRight"], ["HipRight", "KneeRight"], ["KneeRight", "AnkleRight"], ["AnkleRight", "FootRight"],
]

## Kinect TrackingState values.
const STATE_NOT_TRACKED := 0
const STATE_INFERRED := 1
const STATE_TRACKED := 2

var id: String = ""
var joints: Dictionary = {}    # joint name -> Vector3
var tracked: Dictionary = {}   # joint name -> bool (true only for fully tracked joints)
var hand_left: String = "unknown"
var hand_right: String = "unknown"
var hands_up: bool = false
var height: float = 0.0

## Optional silhouette from the depth camera (LA8 pixels, alpha = body mask).
var silhouette: Image = null
var silhouette_center := Vector2i.ZERO   # centroid pixel inside the silhouette


## Fills this body from one entry of the bridge's "bodies" array.
## Returns false when the entry is unusable.
func load_from(raw: Dictionary) -> bool:
	id = str(raw.get("id", ""))
	var raw_joints = raw.get("joints", {})
	if typeof(raw_joints) != TYPE_DICTIONARY:
		return false
	for joint_name in JOINT_NAMES:
		var v = raw_joints.get(joint_name)
		var vt := typeof(v)
		if (vt != TYPE_ARRAY and vt != TYPE_PACKED_FLOAT32_ARRAY and vt != TYPE_PACKED_FLOAT64_ARRAY) or v.size() < 3:
			continue
		joints[joint_name] = Vector3(float(v[0]), float(v[1]), float(v[2]))
		tracked[joint_name] = v.size() < 4 or int(v[3]) == STATE_TRACKED
	var hands = raw.get("hands", {})
	if typeof(hands) == TYPE_DICTIONARY:
		hand_left = str(hands.get("l", "unknown"))
		hand_right = str(hands.get("r", "unknown"))
	hands_up = bool(raw.get("hands_up", false))
	height = float(raw.get("height", 0.0))
	var sil = raw.get("silhouette")
	if typeof(sil) == TYPE_DICTIONARY:
		var w := int(sil.get("w", 0))
		var h := int(sil.get("h", 0))
		# The extension hands over raw bytes; JSON (the UDP bridge) carries them as base64.
		var data = sil.get("data")
		if typeof(data) == TYPE_STRING:
			data = Marshalls.base64_to_raw(data)
		if w > 0 and h > 0 and typeof(data) == TYPE_PACKED_BYTE_ARRAY and data.size() == w * h * 2:
			silhouette = Image.create_from_data(w, h, false, Image.FORMAT_LA8, data)
			silhouette_center = Vector2i(int(sil.get("cx", w / 2)), int(sil.get("cy", h / 2)))
	return joints.has("SpineBase") and joints.has("SpineShoulder") and joints.has("Head")


func has_silhouette() -> bool:
	return silhouette != null


func joint(joint_name: String) -> Vector3:
	return joints.get(joint_name, Vector3.ZERO)


func has_joint(joint_name: String) -> bool:
	return joints.has(joint_name)


func is_joint_tracked(joint_name: String) -> bool:
	return tracked.get(joint_name, false)
