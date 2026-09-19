extends Node
## Autoload "Tracking". Publishes player skeleton frames as BodyData from
## whichever source is available:
##   1. BodyTracker's camera (a depth camera or a plain webcam, see Settings), or
##   2. UDP packets from tools/mock_bridge.py (or any bridge speaking the same JSON).
## Both sources produce the same body dictionaries, so the game never cares.

signal frame_received(bodies: Array)

const DEFAULT_PORT := 7777
const TIMEOUT_SEC := 1.0

var port: int = DEFAULT_PORT
var bodies: Array[BodyData] = []
var packets_received: int = 0
var last_packet_time: float = -100.0
var source: String = "none"   # "camera", "udp" or "none"

var _udp := PacketPeerUDP.new()
var _use_camera := true
var _blob_camera: Node = null   # the depth camera whose blob tracker is wired in (no pose model)
var _tracklog := false        # --tracklog: print a body summary twice a second
var _tracklog_next := 0.0

## The camera in use, or null. It can change while the game runs.
var _camera: Node:
	get: return BodyTracker.camera if _use_camera else null
## True when skeletons come from a pose model rather than the depth-blob tracker.
var _pose_mode: bool:
	get: return BodyTracker.processor.available

## Kinect-style joint names -> MediaPipe joints (averaged). "Left" in the game
## is the image's left, which is the person's right when facing the camera.
const POSE_JOINTS := {
	"Head": ["nose"], "Neck": ["left_shoulder", "right_shoulder", "nose"],
	"SpineShoulder": ["left_shoulder", "right_shoulder"],
	"SpineMid": ["left_shoulder", "right_shoulder", "left_hip", "right_hip"],
	"SpineBase": ["left_hip", "right_hip"],
	"ShoulderLeft": ["right_shoulder"], "ElbowLeft": ["right_elbow"], "WristLeft": ["right_wrist"],
	"HandLeft": ["right_wrist", "right_index"], "HandTipLeft": ["right_index"], "ThumbLeft": ["right_thumb"],
	"ShoulderRight": ["left_shoulder"], "ElbowRight": ["left_elbow"], "WristRight": ["left_wrist"],
	"HandRight": ["left_wrist", "left_index"], "HandTipRight": ["left_index"], "ThumbRight": ["left_thumb"],
	"HipLeft": ["right_hip"], "KneeLeft": ["right_knee"], "AnkleLeft": ["right_ankle"], "FootLeft": ["right_ankle"],
	"HipRight": ["left_hip"], "KneeRight": ["left_knee"], "AnkleRight": ["left_ankle"], "FootRight": ["left_ankle"],
}


## BodyTracker players -> the body frame format the game consumes.
func _on_players_updated(players: Array) -> void:
	var bodies: Array = []
	var now := Time.get_ticks_msec() / 1000.0
	for p in players:
		if not p.visible or now - p.last_seen > 0.3:
			continue
		var joints := {}
		for joint_name in POSE_JOINTS:
			var sum := Vector3.ZERO
			var tracked := true
			var present := true
			for part in POSE_JOINTS[joint_name]:
				var j: TrackedJoint = p.joints[part]
				if j.position_3d == Vector3.ZERO:
					present = false   # never filled (RTMPose has no fingers/heels)
				sum += j.position_3d
				tracked = tracked and j.valid
			if not present:
				continue
			var avg: Vector3 = sum / POSE_JOINTS[joint_name].size()
			if joint_name == "Head":
				avg.y += 0.10
			elif joint_name == "FootLeft" or joint_name == "FootRight":
				avg.y -= 0.08   # ankles sit a hand above the floor
			elif joint_name == "SpineBase":
				avg = p.position   # the tracker's root: torso depth, hips or shoulder-based
			joints[joint_name] = [avg.x, avg.y, avg.z, 2 if tracked else 1]
		bodies.append({"id": str(p.id), "hands": {"l": "tracked", "r": "tracked"},
			"hands_up": p.arms_up, "height": p.standing_height, "joints": joints})
	_on_raw_frame(bodies, "camera")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	port = _port_from_cmdline()
	var err := _udp.bind(port, "0.0.0.0")
	if err != OK:
		push_error("Tracking: could not bind UDP port %d (error %d)" % [port, err])
	else:
		print("Tracking: listening for bridge frames on UDP port %d" % port)

	for arg in OS.get_cmdline_user_args():
		if arg == "--tracklog":
			_tracklog = true
		elif arg == "--no-camera":
			_use_camera = false   # UDP only: leave the camera to an external bridge
	if _use_camera and ClassDB.class_exists("OrbbecCamera"):
		# The smoke tests in CI look for this line.
		print("Tracking: OrbbecCamera extension loaded%s" % (", with WebcamCamera" if ClassDB.class_exists("WebcamCamera") else ""))
		BodyTracker.players_updated.connect(_on_players_updated)
		BodyTracker.camera_changed.connect(_on_camera_changed)
		_on_camera_changed()
	else:
		print("Tracking: OrbbecCamera extension not loaded, using UDP only")


## Skeletons come from the pose model whenever there is one. Without it (a build
## with neither RTMPose nor MediaPipe) a depth camera still has the blob tracker.
func _on_camera_changed() -> void:
	if _blob_camera != null and is_instance_valid(_blob_camera) and _blob_camera.frame_received.is_connected(_on_raw_frame):
		_blob_camera.frame_received.disconnect(_on_raw_frame)
	_blob_camera = null
	var cam := _camera
	if cam == null:
		return
	if _pose_mode:
		print("Tracking: using %s skeletons from %s" % [_engine_name(), BodyTracker.describe_camera()])
	elif BodyTracker.camera_kind == "depth":
		_blob_camera = cam
		cam.frame_received.connect(_on_raw_frame.bind("camera"))
		print("Tracking: pose landmarker unavailable (%s), using the depth-blob tracker" % BodyTracker.processor.last_error)


func _engine_name() -> String:
	return "RTMPose" if BodyTracker.processor is RtmPoseProcessor else "MediaPipe"


## Reads `--tracking-port=<n>` (or `--tracking-port <n>`) from the command line.
## Godot keeps arguments after `--` in get_cmdline_user_args() and the rest in
## get_cmdline_args(), so both are checked. Falls back to DEFAULT_PORT.
func _port_from_cmdline() -> int:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for i in args.size():
		var arg: String = args[i]
		var value := ""
		if arg.begins_with("--tracking-port="):
			value = arg.get_slice("=", 1)
		elif arg == "--tracking-port" and i + 1 < args.size():
			value = args[i + 1]
		else:
			continue
		if value.is_valid_int() and int(value) > 0 and int(value) < 65536:
			print("Tracking: UDP port %s from the command line" % value)
			return int(value)
		push_warning("Tracking: ignoring invalid --tracking-port value '%s'" % value)
	return DEFAULT_PORT


## True while frames keep arriving from any source.
func is_connected_to_source() -> bool:
	return Time.get_ticks_msec() / 1000.0 - last_packet_time < TIMEOUT_SEC


func has_camera() -> bool:
	return _camera != null and _camera.is_running()


## Only the depth-blob tracker learns a background; pose tracking never waits.
func is_background_ready() -> bool:
	return _blob_camera == null or not _blob_camera.is_running() or _blob_camera.is_background_ready()


## Debug image from the depth camera (depth + blobs + markers), or null.
func get_camera_debug_image() -> Image:
	var cam := BodyTracker.depth_camera if _use_camera else null
	if cam == null or not cam.is_running():
		return null
	return cam.get_debug_image()


func set_camera_debug(enabled: bool) -> void:
	var cam := BodyTracker.depth_camera if _use_camera else null
	if cam != null:
		cam.set_debug_enabled(enabled)


## Re-learn the empty room. Players should step out of view for a second.
func learn_background() -> void:
	if _blob_camera != null and _blob_camera.is_running():
		_blob_camera.learn_background()
		print("Tracking: re-learning background")


func source_description() -> String:
	if has_camera() and _pose_mode:
		var warn := ""
		for p in BodyTracker.players:
			if p.visible and p.position.z > 0.0 and p.position.z < 1.2:
				warn = "   TOO CLOSE: step back to 2 m so the whole body is in view"
		return "Camera: %s  %s %.0f poses/s, %.0f ms (%d bodies)%s" % [BodyTracker.describe_camera(), _engine_name(), BodyTracker.processor.poses_per_second, BodyTracker.processor.inference_ms, bodies.size(), warn]
	if has_camera():
		if not is_background_ready():
			return "Camera: %s  -  learning the empty room, stay out of view" % BodyTracker.describe_camera()
		return "Camera: %s (%d bodies)  -  %s" % [BodyTracker.describe_camera(), bodies.size(), BodyTracker.status]
	if not is_connected_to_source():
		if _use_camera and (BodyTracker.depth_camera != null or BodyTracker.webcam != null):
			return "%s  -  Esc: settings" % BodyTracker.status
		return "No tracking source  -  run tools/mock_bridge.py"
	return "UDP bridge on port %d (%d bodies)" % [port, bodies.size()]


func _process(_delta: float) -> void:
	# Drain the socket and keep only the newest packet; stale frames are useless.
	var latest := PackedByteArray()
	var got_packet := false
	while _udp.get_available_packet_count() > 0:
		latest = _udp.get_packet()
		got_packet = true
	if not got_packet:
		return
	# The camera wins while it is delivering frames.
	if source == "camera" and is_connected_to_source():
		return

	var parsed = JSON.parse_string(latest.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var raw_bodies = parsed.get("bodies", [])
	if typeof(raw_bodies) != TYPE_ARRAY:
		return
	_on_raw_frame(raw_bodies, "udp")


func _on_raw_frame(raw_bodies: Array, from_source: String) -> void:
	packets_received += 1
	last_packet_time = Time.get_ticks_msec() / 1000.0
	source = from_source

	var new_bodies: Array[BodyData] = []
	for raw in raw_bodies:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var body := BodyData.new()
		if body.load_from(raw):
			new_bodies.append(body)
	bodies = new_bodies
	frame_received.emit(bodies)
	if _tracklog and last_packet_time >= _tracklog_next:
		_tracklog_next = last_packet_time + 0.5
		var parts: Array[String] = []
		for b in bodies:
			var base := b.joint("SpineBase")
			var hl := b.joint("HandLeft") - b.joint("SpineShoulder")
			var hr := b.joint("HandRight") - b.joint("SpineShoulder")
			parts.append("id=%s h=%.2f x=%.2f z=%.2f L=(%.2f,%.2f,%.2f)%s R=(%.2f,%.2f,%.2f)%s%s" % [
				b.id, b.height, base.x, base.z, hl.x, hl.y, hl.z, "*" if b.hand_left == "tracked" else "",
				hr.x, hr.y, hr.z, "*" if b.hand_right == "tracked" else "", " UP" if b.hands_up else ""])
		var rate := ""
		if _pose_mode:
			rate = " pose=%.0f/s %.0fms" % [BodyTracker.processor.poses_per_second, BodyTracker.processor.inference_ms]
		print("tracklog t=%.1f n=%d%s  %s" % [last_packet_time, bodies.size(), rate, "  |  ".join(parts)])
