class_name PoseProcessor
extends RefCounted
## Runs MediaPipe Pose Landmarker (via GDMP) on Gemini color frames and fuses
## Gemini depth into every landmark. Inference runs on MediaPipe's own thread in
## live-stream mode; results are handed back to the main thread with call_deferred.
##
## Output per person (a Dictionary):
##   "root": Vector3, "landmarks": Array of {name, normalized: Vector2, pixel: Vector2,
##   position_3d: Vector3, visibility, presence, depth_ok: bool, depth_inferred: bool}
##   "timestamp_ms": int (camera timestamp of the frame the pose came from)

signal poses_ready(people: Array, timestamp_ms: int)

const MODEL_PATH := "res://models/pose_landmarker_lite.task"
const DEPTH_HOLD_S := 0.3      # carry a joint's last depth this long when the sensor has none

var num_poses := 2
var min_pose_detection_confidence := 0.5
var min_pose_presence_confidence := 0.5
var min_tracking_confidence := 0.5
var sample_radius := 2         # 5x5 median window, widened to 9x9 as a fallback
var min_depth_m := 0.4
var max_depth_m := 5.0

var available := false
var last_error := ""
var inference_ms := 0.0        # camera frame -> result, wall clock
var poses_per_second := 0.0

var _camera: Node
var _task = null                # MediaPipePoseLandmarker
var _in_flight := false
var _sent_frame_id := -1
var _sent_at := 0.0
var _sent_ts := 0
var _result_times: Array[float] = []
var _last_depth: Dictionary = {}   # "pose_index:joint" -> [depth, time]


func setup(camera: Node) -> bool:
	_camera = camera
	if not ClassDB.class_exists("MediaPipePoseLandmarker"):
		last_error = "GDMP extension not loaded"
		return false
	if not FileAccess.file_exists(MODEL_PATH):
		last_error = "model missing: " + MODEL_PATH
		return false
	var base_options = ClassDB.instantiate("MediaPipeTaskBaseOptions")
	base_options.delegate = base_options.DELEGATE_CPU
	base_options.model_asset_buffer = FileAccess.get_file_as_bytes(MODEL_PATH)
	_task = ClassDB.instantiate("MediaPipePoseLandmarker")
	var live_stream: int = ClassDB.class_get_integer_constant("MediaPipeVisionTask", "RUNNING_MODE_LIVE_STREAM")
	var ok: bool = _task.initialize(base_options, live_stream, num_poses,
		min_pose_detection_confidence, min_pose_presence_confidence, min_tracking_confidence, false)
	if not ok:
		last_error = "pose landmarker failed to initialize"
		_task = null
		return false
	_task.result_callback.connect(_on_result)
	available = true
	return true


## Call every frame from the main thread; pushes a new color frame when the previous
## inference has returned, so stale frames are dropped instead of queued.
func poll() -> void:
	if not available or _in_flight or _camera == null or not _camera.is_running():
		return
	var frame_id: int = _camera.get_color_frame_id()
	if frame_id == _sent_frame_id or frame_id == 0:
		return
	var image: Image = _camera.get_color_image()
	if image == null:
		return
	var mp_image = ClassDB.instantiate("MediaPipeImage")
	mp_image.set_image(image)
	_sent_frame_id = frame_id
	_sent_at = Time.get_ticks_msec() / 1000.0
	_sent_ts = int(_camera.get_timestamp())
	# Timestamps must increase strictly; use our own clock in ms.
	var ts := Time.get_ticks_msec()
	_in_flight = true
	if not _task.detect_async(mp_image, ts, Rect2(), 0):
		_in_flight = false


## MediaPipe thread: copy the numbers out, then hop to the main thread.
func _on_result(result, _image, timestamp_ms: int) -> void:
	var people: Array = []
	var lists = result.get_pose_landmarks()
	for i in lists.size():
		var lms = lists[i].get_landmarks()
		var raw: Array = []
		for j in lms.size():
			var lm = lms[j]
			raw.append([lm.get_x(), lm.get_y(), lm.get_z(),
				lm.get_visibility() if lm.has_visibility() else 1.0,
				lm.get_presence() if lm.has_presence() else 1.0])
		people.append(raw)
	call_deferred("_fuse_and_emit", people, timestamp_ms)


## Main thread: depth fusion, deprojection, then emit.
func _fuse_and_emit(raw_people: Array, timestamp_ms: int) -> void:
	_in_flight = false
	var now := Time.get_ticks_msec() / 1000.0
	inference_ms = (now - _sent_at) * 1000.0
	_result_times.append(now)
	while _result_times.size() > 0 and now - _result_times[0] > 2.0:
		_result_times.pop_front()
	poses_per_second = _result_times.size() / 2.0

	var w: int = _camera.get_color_width()
	var h: int = _camera.get_color_height()
	if w == 0 or h == 0:
		return
	var people: Array = []
	for pi in raw_people.size():
		var raw: Array = raw_people[pi]
		var landmarks: Array = []
		var torso_depths: Array[float] = []
		# First pass: pixel positions and raw depth.
		for j in raw.size():
			var r: Array = raw[j]
			var px := Vector2(r[0] * w, r[1] * h)
			var depth: float = 0.0
			if px.x >= 0 and px.y >= 0 and px.x < w and px.y < h:
				depth = _camera.get_depth_at(int(px.x), int(px.y), sample_radius)
				if depth <= 0.0:
					depth = _camera.get_depth_at(int(px.x), int(px.y), sample_radius * 2)
			if depth < min_depth_m or depth > max_depth_m:
				depth = 0.0
			landmarks.append({"index": j, "normalized": Vector2(r[0], r[1]), "pixel": px,
				"depth": depth, "visibility": r[3], "presence": r[4], "mp_z": r[2]})
			if j in [11, 12, 23, 24] and depth > 0.0:
				torso_depths.append(depth)
		if torso_depths.is_empty():
			continue
		torso_depths.sort()
		var torso_z: float = torso_depths[torso_depths.size() / 2]
		# Second pass: fallbacks and deprojection.
		for lm in landmarks:
			var key := "%d:%d" % [pi, lm["index"]]
			var depth: float = lm["depth"]
			lm["depth_inferred"] = false
			if depth > 0.0 and absf(depth - torso_z) > 1.2:
				depth = 0.0   # a reading from the background behind a raised hand
			if depth <= 0.0 and _last_depth.has(key) and now - _last_depth[key][1] < DEPTH_HOLD_S:
				depth = _last_depth[key][0]
				lm["depth_inferred"] = true
			if depth <= 0.0:
				# No sensor reading for this joint: use the torso depth, flagged as inferred.
				depth = torso_z
				lm["depth_inferred"] = true
			elif not lm["depth_inferred"]:
				_last_depth[key] = [depth, now]
			lm["depth_ok"] = true
			lm["position_3d"] = _camera.deproject_pixel(lm["pixel"].x, lm["pixel"].y, depth)
		var lh: Vector3 = landmarks[23]["position_3d"]
		var rh: Vector3 = landmarks[24]["position_3d"]
		var vis_sum := 0.0
		for lm in landmarks:
			vis_sum += lm["visibility"]
		people.append({"root": (lh + rh) * 0.5, "landmarks": landmarks, "timestamp_ms": timestamp_ms,
			"score": vis_sum / landmarks.size()})
	# MediaPipe sometimes reports the same person twice; keep the better-seen one.
	people.sort_custom(func(a, b): return a["score"] > b["score"])
	var kept: Array = []
	for person in people:
		var dup := false
		for other in kept:
			if Vector2(person["root"].x, person["root"].z).distance_to(Vector2(other["root"].x, other["root"].z)) < 0.35:
				dup = true
				break
		if not dup:
			kept.append(person)
	poses_ready.emit(kept, timestamp_ms)
