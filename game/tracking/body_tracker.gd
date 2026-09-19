extends Node
## Autoload "BodyTracker": the game-facing tracking API.
##
##   var p := BodyTracker.get_player(0)
##   if p: print(p.right_hand.position_3d, p.right_hand.velocity)
##   BodyTracker.gesture.connect(func(player, name): ...)
##
## Owns the camera, the pose processor, identity tracking, filtering, velocities
## and gestures. The camera is whichever the Settings autoload allows:
##   "depth"  RGB + depth - OrbbecCamera (Gemini 2): every joint gets a measured distance
##   "rgb"    RGB only    - WebcamCamera (any webcam): distance estimated from body size
##   "auto"   the depth camera when one is plugged in, a webcam otherwise
## Camera space is meters: +x right (image right), +y up, +z away from the camera.

signal player_entered(player: TrackedPlayer)
signal player_left(player: TrackedPlayer)
signal tracking_started()
signal tracking_lost()
signal gesture(player: TrackedPlayer, gesture_name: String)
signal players_updated(players: Array)
## The camera in use changed (another device, another kind, or none).
signal camera_changed()

const CAMERA_RETRY_S := 3.0

var camera: Node = null            # the camera in use, null until one starts
var camera_kind := ""              # "depth" or "rgb": what `camera` is
var depth_camera: Node = null      # OrbbecCamera, when the mode allows one
var webcam: Node = null            # WebcamCamera, when the mode allows one
## RTMPose (in the extension, ONNX Runtime) when the build carries it, MediaPipe
## (GDMP) otherwise. Both emit the same people, so nothing else knows which runs.
var processor = PoseProcessor.new()
var identity := PlayerIdentityTracker.new()
var gestures := GestureDetector.new()
var enabled := true
var status := "starting"
var camera_fps := 0.0
var last_pose_time := 0.0

var _rtm: RtmPoseProcessor = null
var _rtm_error := ""
var _mediapipe: PoseProcessor = null
var _force_mediapipe := false
var _camera_retry_at := 0.0
var _configure_queued := false
var _was_tracking := false
var _handlog := false
var _frame_times: Array[float] = []
var _last_frame_id := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # tracking keeps running behind the settings menu
	for arg in OS.get_cmdline_user_args():
		if arg == "--no-camera":
			enabled = false
		elif arg == "--handlog":
			_handlog = true
		elif arg == "--mediapipe":
			_force_mediapipe = true
	if not enabled:
		status = "disabled (--no-camera)"
		return
	gestures.sensitivity = Settings.sensitivity_factor()
	Settings.changed.connect(_on_setting_changed)
	_rtm = RtmPoseProcessor.new()
	if _force_mediapipe:
		_rtm_error = "--mediapipe"
	elif _rtm.load_model():
		_rtm.poses_ready.connect(_on_poses)
	else:
		_rtm_error = _rtm.last_error
	_configure()


func _on_setting_changed(key: String) -> void:
	match key:
		"camera_mode", "webcam_name", "webcam_index":
			# The menu sets the name and the index together: reconfigure once.
			if not _configure_queued:
				_configure_queued = true
				_configure.call_deferred()
		"webcam_fov":
			if webcam != null:
				webcam.set_horizontal_fov(Settings.webcam_fov)
		"sensitivity":
			gestures.sensitivity = Settings.sensitivity_factor()


## Creates the camera nodes the mode allows and starts the first that works.
func _configure() -> void:
	_configure_queued = false
	_release_cameras()
	var mode := Settings.camera_mode
	if mode != Settings.CAMERA_RGB and ClassDB.class_exists("OrbbecCamera"):
		depth_camera = ClassDB.instantiate("OrbbecCamera")
		add_child(depth_camera)
	if mode != Settings.CAMERA_DEPTH and ClassDB.class_exists("WebcamCamera"):
		webcam = ClassDB.instantiate("WebcamCamera")
		add_child(webcam)
	if depth_camera == null and webcam == null:
		status = "camera extension not loaded"
		camera_changed.emit()
		return
	_try_start_camera()
	if camera == null:
		camera_changed.emit()


func _release_cameras() -> void:
	processor.set_camera(null)
	for node in [depth_camera, webcam]:
		if node != null:
			node.stop()
			node.queue_free()
	depth_camera = null
	webcam = null
	camera = null
	camera_kind = ""
	camera_fps = 0.0
	_frame_times.clear()
	_forget_players()


func _forget_players() -> void:
	for p in identity.clear():
		p.visible = false
		player_left.emit(p)


func _try_start_camera() -> void:
	_camera_retry_at = Time.get_ticks_msec() / 1000.0 + CAMERA_RETRY_S
	var problems: Array[String] = []
	for candidate in [[depth_camera, "depth"], [webcam, "rgb"]]:
		var node: Node = candidate[0]
		if node == null:
			continue
		if candidate[1] == "rgb":
			_select_webcam()
		if node.start():
			_use_camera(node, candidate[1])
			return
		problems.append("%s: %s" % ["depth camera" if candidate[1] == "depth" else "webcam", node.get_last_error()])
	status = "No camera (%s)" % ", ".join(problems)


## The webcam the player picked, by name. Before they pick one, the likeliest
## to be pointed at them.
func _select_webcam() -> void:
	webcam.set_device(preferred_webcam(webcam.list_devices()))
	webcam.set_horizontal_fov(Settings.webcam_fov)


## Index into `names` of the webcam to use: the saved name, else the saved index
## when the player chose one, else the best guess - a tablet lists its rear
## camera first, and phone-as-webcam drivers show up even when the phone is away.
func preferred_webcam(names: PackedStringArray) -> int:
	var saved := names.find(Settings.webcam_name) if Settings.webcam_name != "" else -1
	if saved >= 0:
		return saved
	if (Settings.webcam_index > 0 or Settings.is_overridden("webcam_index")) and Settings.webcam_index < names.size():
		return Settings.webcam_index
	var best := 0
	var best_score := -100
	for i in names.size():
		var n := names[i].to_lower()
		var score := 0
		for good in ["front", "integrated", "facetime", "webcam", "user facing"]:
			if good in n:
				score += 2
		for bad in ["rear", "back", "virtual", "infrared", " ir ", "depth", "obs"]:
			if bad in n:
				score -= 2
		if score > best_score:
			best_score = score
			best = i
	return best


func _use_camera(node: Node, kind: String) -> void:
	camera = node
	camera_kind = kind
	status = "camera: " + node.get_device_name()
	_frame_times.clear()
	_forget_players()
	# Reach inferred from a foreshortened arm reads short of a measured one.
	gestures.forward_scale = 0.75 if kind == "rgb" else 1.0
	if _rtm_error == "":
		processor = _rtm
		_rtm.set_camera(camera)
		print("BodyTracker: %s, RTMPose %s" % [describe_camera(), "with depth" if kind == "depth" else "on RGB only (distance from body size)"])
	elif kind == "depth":
		if _mediapipe == null:
			_mediapipe = PoseProcessor.new()
			_mediapipe.poses_ready.connect(_on_poses)
		processor = _mediapipe
		if _mediapipe.setup(camera):
			print("BodyTracker: %s, MediaPipe pose landmarker (RTMPose: %s)" % [describe_camera(), _rtm_error])
		else:
			status = "pose: " + _mediapipe.last_error + " / RTMPose: " + _rtm_error
			push_warning("BodyTracker: " + status)
	else:
		status = "a webcam needs RTMPose, which this build lacks (%s)" % _rtm_error
		push_warning("BodyTracker: " + status)
	camera_changed.emit()


## "Orbbec Gemini 2 (RGB + depth)", "Surface Camera Front (RGB)", or "" with no camera.
func describe_camera() -> String:
	if camera == null:
		return ""
	return "%s (%s)" % [camera.get_device_name(), "RGB + depth" if camera_kind == "depth" else "RGB"]


## Look for cameras again with the current settings: for a camera plugged in
## after the game started (auto mode does not leave a working webcam by itself).
func rescan() -> void:
	_configure()


## Webcam names for the settings menu, in device index order.
func list_webcams() -> PackedStringArray:
	if webcam != null:
		return webcam.list_devices()
	if not ClassDB.class_exists("WebcamCamera"):
		return PackedStringArray()
	var probe: Node = ClassDB.instantiate("WebcamCamera")
	var names: PackedStringArray = probe.list_devices()
	probe.free()
	return names


func _process(_delta: float) -> void:
	if depth_camera == null and webcam == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if camera != null and not camera.is_running():
		# Unplugged, or taken by another app: say why and look again.
		status = "camera lost: " + camera.get_last_error()
		push_warning("BodyTracker: " + status)
		processor.set_camera(null)
		camera = null
		camera_kind = ""
		_forget_players()
		camera_changed.emit()
		_camera_retry_at = now + 1.0
	if camera == null:
		if now >= _camera_retry_at:
			_try_start_camera()
		if camera == null:
			return
	var fid: int = camera.get_color_frame_id()
	if fid != _last_frame_id:
		_last_frame_id = fid
		_frame_times.append(now)
	while _frame_times.size() > 0 and now - _frame_times[0] > 2.0:
		_frame_times.pop_front()
	camera_fps = _frame_times.size() / 2.0
	processor.poll()
	# Expire players that vanished.
	for p in identity.expire(now):
		p.visible = false
		player_left.emit(p)
	var tracking := not identity.players.is_empty()
	if tracking != _was_tracking:
		_was_tracking = tracking
		if tracking:
			tracking_started.emit()
		else:
			tracking_lost.emit()


## Players sorted by id; index 0 is Player 1.
var players: Array:
	get:
		var arr := identity.players.values()
		arr.sort_custom(func(a, b): return a.id < b.id)
		return arr

var player_count: int:
	get: return identity.players.size()


func get_player(index: int) -> TrackedPlayer:
	var arr := players
	return arr[index] if index < arr.size() else null


func _on_poses(people: Array, _timestamp_ms: int) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	last_pose_time = now
	var assigned := identity.assign(people, now)
	for k in people.size():
		var det: Dictionary = people[k]
		var p: TrackedPlayer = assigned[k]
		var is_new := p.last_seen == 0.0
		if is_new:
			p.first_seen = now
		_update_player(p, det, now)
		if is_new:
			player_entered.emit(p)
		var fired := gestures.update(p, now)
		for g in fired:
			gesture.emit(p, g)
		if _handlog:
			var sh := (p.left_shoulder.raw_position + p.right_shoulder.raw_position) * 0.5
			var l := p.left_hand
			var r := p.right_hand
			var dl := 0.0
			var dr := 0.0
			for lm in det["landmarks"]:
				if lm["index"] == 15: dl = float(lm.get("depth_raw", 0.0))
				elif lm["index"] == 16: dr = float(lm.get("depth_raw", 0.0))
			print("hand t=%.2f id=%d z_sh=%.2f  L fwd=%.2f vz=%+.1f x=%.2f c=%.2f%s arm=%.2f  R fwd=%.2f vz=%+.1f x=%.2f c=%.2f%s arm=%.2f %s" % [
				now, p.id, sh.z, sh.z - l.raw_position.z, l.velocity.z, l.raw_position.x, l.confidence, "i" if l.depth_inferred else "", dl,
				sh.z - r.raw_position.z, r.velocity.z, r.raw_position.x, r.confidence, "i" if r.depth_inferred else "", dr,
				" ".join(fired)])
	players_updated.emit(players)


func _update_player(p: TrackedPlayer, det: Dictionary, now: float) -> void:
	var dt := clampf(now - p.last_seen, 1.0 / 60.0, 0.5) if p.last_seen > 0.0 else 1.0 / 30.0
	var conf_sum := 0.0
	for lm in det["landmarks"]:
		var name: String = TrackedPlayer.JOINT_NAMES[lm["index"]]
		var j: TrackedJoint = p.joints[name]
		j.normalized_position = lm["normalized"]
		j.image_position = lm["pixel"]
		j.visibility = lm["visibility"]
		j.confidence = minf(lm["visibility"], lm["presence"])
		j.depth_inferred = lm["depth_inferred"]
		var raw: Vector3 = lm["position_3d"]
		var f: PoseFilter = p.filter_for(name)
		var was_valid := j.valid
		j.valid = j.confidence > 0.3
		if j.valid:
			if not was_valid:
				f.reset()
			var filtered := f.filter(raw, now)
			# Velocity from the raw samples (lightly smoothed) so fast punches are not damped away.
			var raw_v := (raw - j.raw_position) / dt if was_valid else Vector3.ZERO
			j.velocity = j.velocity.lerp(raw_v, 0.6) if was_valid else Vector3.ZERO
			j.raw_position = raw
			j.position_3d = filtered
		else:
			# Never leave a joint at the origin: keep its last position, or follow the root.
			j.velocity = Vector3.ZERO
			if j.position_3d == Vector3.ZERO or p.last_seen == 0.0:
				j.position_3d = det["root"] + (raw - det["root"]).limit_length(0.9)
			j.raw_position = j.position_3d
		conf_sum += j.confidence
	p.tracking_confidence = conf_sum / maxf(1.0, det["landmarks"].size())
	var root: Vector3 = det["root"]
	p.velocity = (root - p.position) / dt if p.last_seen > 0.0 else Vector3.ZERO
	p.position = root
	p.visible = true
	p.last_seen = now
	# Standing height: head to lowest ankle, as the median of recent readings so a
	# single bad frame cannot inflate it.
	if p.left_foot.valid and p.right_foot.valid and not p.left_foot.depth_inferred and not p.right_foot.depth_inferred:
		var feet_y := minf(p.left_foot.position_3d.y, p.right_foot.position_3d.y)
		var h := p.head.position_3d.y - feet_y + 0.12
		if h > 0.5 and h < 2.3:
			p.height_samples.append(h)
			if p.height_samples.size() > 90:
				p.height_samples.pop_front()
			var sorted := p.height_samples.duplicate()
			sorted.sort()
			p.standing_height = sorted[sorted.size() / 2]
	elif p.standing_height == 0.0 and p.head.valid and p.joints["left_hip"].valid:
		# Feet out of view (player close): estimate from head-to-hips, refined once feet appear.
		var torso := p.head.position_3d.y - p.position.y
		if torso > 0.3 and torso < 1.2:
			p.standing_height = torso * 1.9
