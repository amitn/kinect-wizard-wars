extends Node
## Autoload "BodyTracker": the game-facing tracking API.
##
##   var p := BodyTracker.get_player(0)
##   if p: print(p.right_hand.position_3d, p.right_hand.velocity)
##   BodyTracker.gesture.connect(func(player, name): ...)
##
## Owns the Gemini camera node (OrbbecCamera extension), the MediaPipe pose
## processor, identity tracking, filtering, velocities and gestures.
## Camera space is meters: +x right (image right), +y up, +z away from the camera.

signal player_entered(player: TrackedPlayer)
signal player_left(player: TrackedPlayer)
signal tracking_started()
signal tracking_lost()
signal gesture(player: TrackedPlayer, gesture_name: String)
signal players_updated(players: Array)

var camera: Node = null            # OrbbecCamera, or null when the extension is missing
## RTMPose (in the extension, ONNX Runtime) when the build carries it, MediaPipe
## (GDMP) otherwise. Both emit the same people, so nothing else knows which runs.
var processor = PoseProcessor.new()
var identity := PlayerIdentityTracker.new()
var gestures := GestureDetector.new()
var enabled := true
var status := "starting"
var camera_fps := 0.0
var last_pose_time := 0.0

var _camera_retry_at := 0.0
var _was_tracking := false
var _handlog := false
var _frame_times: Array[float] = []
var _last_frame_id := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--no-camera":
			enabled = false
		elif arg == "--handlog":
			_handlog = true
	if not enabled:
		status = "disabled (--no-camera)"
		return
	if ClassDB.class_exists("OrbbecCamera"):
		camera = ClassDB.instantiate("OrbbecCamera")
		add_child(camera)
		_try_start_camera()
	else:
		status = "OrbbecCamera extension not loaded"
	if camera != null:
		var force_mediapipe := false
		for arg in OS.get_cmdline_user_args():
			if arg == "--mediapipe":
				force_mediapipe = true
		var rtm := RtmPoseProcessor.new()
		var rtm_error := "--mediapipe" if force_mediapipe else ""
		if not force_mediapipe:
			if rtm.setup(camera):
				processor = rtm
			else:
				rtm_error = rtm.last_error
		if processor == rtm:
			processor.poses_ready.connect(_on_poses)
			print("BodyTracker: RTMPose ready (in-extension, boxes from depth)")
		elif processor.setup(camera):
			processor.poses_ready.connect(_on_poses)
			print("BodyTracker: MediaPipe pose landmarker ready (RTMPose: %s)" % rtm_error)
		else:
			status = "pose: " + processor.last_error + " / RTMPose: " + rtm_error
			push_warning("BodyTracker: " + status)


func _try_start_camera() -> void:
	if camera == null or camera.is_running():
		return
	if camera.start():
		status = "camera: " + camera.get_device_name()
	else:
		status = "no camera: " + camera.get_last_error()
	_camera_retry_at = Time.get_ticks_msec() / 1000.0 + 3.0


func _process(_delta: float) -> void:
	if camera == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if not camera.is_running() and now >= _camera_retry_at:
		_try_start_camera()
	if camera.is_running():
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
			print("hand t=%.2f id=%d z_sh=%.2f  L fwd=%.2f vz=%+.1f x=%.2f c=%.2f%s  R fwd=%.2f vz=%+.1f x=%.2f c=%.2f%s %s" % [
				now, p.id, sh.z, sh.z - l.raw_position.z, l.velocity.z, l.raw_position.x, l.confidence, "i" if l.depth_inferred else "",
				sh.z - r.raw_position.z, r.velocity.z, r.raw_position.x, r.confidence, "i" if r.depth_inferred else "",
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
