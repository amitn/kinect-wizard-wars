class_name RtmPoseProcessor
extends RefCounted
## RTMPose in place of MediaPipe, with the same output contract.
##
## A drop-in alternative to pose_processor.gd: it emits the same `poses_ready`
## people, so BodyTracker, TrackedPlayer and every game above them are unchanged
## and cannot tell which one is running.
##
## Three differences worth knowing:
##   - Inference happens inside the extension (RtmPose, ONNX Runtime's C API),
##     measured at 6.6 ms a person here against MediaPipe's 32 to 48.
##   - There is no person detector. A top-down pose model needs a box around
##     somebody, and the usual answer is a second network costing more than the
##     pose model. Instead this sweeps one candidate crop across the frame while
##     nobody is tracked - RTMPose is cheap enough to be its own detector - and
##     once somebody is found, their next box comes from their own keypoints.
##     Depth boxes come along as extra candidates when the room is empty enough
##     for them to mean anything, but nothing depends on them: in a real room
##     the furniture is all at play distance and connects everyone into one blob.
##   - RTMPose speaks COCO-17, so there are no fingers. The wrists stand in for
##     them, which is all this game reads anyway.

signal poses_ready(people: Array, timestamp_ms: int)

const MODEL_PATH := "res://models/rtmpose-t.onnx"

## COCO-17 in RTMPose order -> the MediaPipe indices TrackedPlayer.JOINT_NAMES uses.
const COCO_TO_JOINT := [0, 2, 5, 7, 8, 11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28]
const COCO_LEFT_WRIST := 9
const COCO_RIGHT_WRIST := 10
const COCO_LEFT_ELBOW := 7
const COCO_RIGHT_ELBOW := 8
const COCO_SHOULDERS := [5, 6]
const COCO_HIPS := [11, 12]
## Wrists and elbows read the nearest surface; a hand is in front of what is
## behind it, and a median window would happily return the wall.
const NEAR_SURFACE := [7, 8, 9, 10]

var num_poses := 2
var min_score := 0.45         # mean keypoint confidence for a real person (people score 0.65+, furniture and plants 0.25 to 0.35)
var play_near_m := 0.8
var play_far_m := 3.6
var arm_depth_limit_m := 0.8
var sample_radius := 2

var available := false
var last_error := ""
var inference_ms := 0.0
var poses_per_second := 0.0
var grab_ms := 0.0
var convert_ms := 0.0
var boxes_ms := 0.0           # finding people in the depth image
var last_boxes: Array = []    # what the depth camera thought was a person, for the F2 view
var people_ms := 0.0          # RTMPose itself, all people
## Kept so the debug panel reads the same for either processor.
var input_scale := 1.0
var use_gpu := false
var has_percentile := true

var _camera: Node
var _pose = null               # RtmPose, from the extension
var _last_frame_id := -1
var _log := false
var _log_next := 0.0
var _tracks: Array = []        # [{box: Rect2, seen: float}] - people we are following
var _scan := 0                 # which candidate crop to sweep next
const SCAN_COLUMNS := 4
const TRACK_MEMORY := 0.6      # seconds a track survives without being confirmed
const BOX_SMOOTHING := 0.2     # how fast the crop follows the keypoints it found
var _result_times: Array[float] = []


func setup(camera: Node) -> bool:
	_camera = camera
	available = false
	if not ClassDB.class_exists("RtmPose"):
		last_error = "RtmPose not in the extension (build with onnxruntime=<dir>)"
		return false
	if not FileAccess.file_exists(MODEL_PATH):
		last_error = "model missing: " + MODEL_PATH + " (tools/fetch_rtmpose_model.sh)"
		return false
	if camera == null or not camera.has_method("get_person_boxes"):
		last_error = "this OrbbecCamera build has no get_person_boxes"
		return false
	var file := FileAccess.open(MODEL_PATH, FileAccess.READ)
	if file == null:
		last_error = "could not read " + MODEL_PATH
		return false
	_pose = ClassDB.instantiate("RtmPose")
	# Two threads: this shares a CPU with the game loop and MediaPipe's old habit
	# of taking everything is half of why frames were being missed.
	if not _pose.initialize(file.get_buffer(file.get_length()), 3):
		last_error = _pose.get_last_error()
		_pose = null
		return false
	for arg in OS.get_cmdline_user_args():
		if arg == "--tracklog":
			_log = true
	available = true
	last_error = ""
	return true


## Called every frame from the main thread, like the MediaPipe processor. Unlike
## it, this is synchronous: at 6.6 ms a person there is nothing to gain from a
## worker thread and a frame of extra latency.
func poll() -> void:
	if not available or _camera == null or not _camera.is_running():
		return
	var frame_id: int = _camera.get_color_frame_id()
	if frame_id == _last_frame_id or frame_id == 0:
		return
	_last_frame_id = frame_id

	var started := Time.get_ticks_usec()
	var image: Image = _camera.get_color_image()
	if image == null:
		return
	grab_ms = (Time.get_ticks_usec() - started) / 1000.0

	var boxes_started := Time.get_ticks_usec()
	var boxes := _candidate_boxes(image.get_width(), image.get_height())
	boxes_ms = (Time.get_ticks_usec() - boxes_started) / 1000.0
	last_boxes = boxes

	var people_started := Time.get_ticks_usec()
	var people: Array = []
	var now_s := Time.get_ticks_msec() / 1000.0
	var found: Array = []
	for box in boxes:
		var person := _person_from_box(image, box)
		if person.is_empty():
			continue
		# Do not report the same person twice when a scan crop lands on somebody
		# who is already being tracked.
		var duplicate := false
		for other in people:
			if other["root"].distance_to(person["root"]) < 0.45:
				duplicate = true
				break
		if duplicate:
			continue
		people.append(person)
		found.append(person["box"])
		if people.size() >= num_poses:
			break
	_update_tracks(found, now_s)

	people_ms = (Time.get_ticks_usec() - people_started) / 1000.0
	var now := Time.get_ticks_msec() / 1000.0
	inference_ms = (Time.get_ticks_usec() - started) / 1000.0
	convert_ms = _pose.get_preprocess_ms()
	_result_times.append(now)
	while _result_times.size() > 0 and now - _result_times[0] > 2.0:
		_result_times.pop_front()
	poses_per_second = _result_times.size() / 2.0
	if not people.is_empty():
		poses_ready.emit(people, int(_camera.get_timestamp()))


## Boxes to try this frame: everyone already being followed, plus one slice of
## the frame swept across in turn while there is room for another player. One
## extra pose inference a frame is a fraction of what a detector network costs,
## and it works in a kitchen.
func _candidate_boxes(width: int, height: int) -> Array:
	var now_s := Time.get_ticks_msec() / 1000.0
	var boxes: Array = []
	for track in _tracks:
		if now_s - track["seen"] < TRACK_MEMORY:
			boxes.append(track["box"])
	if boxes.size() < num_poses:
		var slice_w := float(width) / float(SCAN_COLUMNS) * 1.6
		var step := (float(width) - slice_w) / float(maxi(SCAN_COLUMNS - 1, 1))
		var x := step * float(_scan % SCAN_COLUMNS)
		_scan += 1
		var candidate := Rect2(x, 0.0, slice_w, float(height))
		var overlaps := false
		for box in boxes:
			if box.intersects(candidate) and box.intersection(candidate).get_area() > box.get_area() * 0.5:
				overlaps = true
				break
		if not overlaps:
			boxes.append(candidate)
	return boxes


## A confirmed person's next box is their own keypoints, padded. Tracks that go
## unconfirmed for TRACK_MEMORY are dropped and the sweep picks them up again.
func _update_tracks(found: Array, now_s: float) -> void:
	var kept: Array = []
	for box in found:
		# Ease the box toward the new keypoints instead of snapping to them. The
		# crop decides what the model sees, so a box that chases every frame's
		# jitter feeds that jitter straight back into the keypoints it came from.
		var smoothed: Rect2 = box
		for track in _tracks:
			var previous: Rect2 = track["box"]
			if previous.intersects(box):
				smoothed = Rect2(previous.position.lerp(box.position, BOX_SMOOTHING),
						previous.size.lerp(box.size, BOX_SMOOTHING))
				break
		kept.append({"box": smoothed, "seen": now_s})
	for track in _tracks:
		if now_s - track["seen"] >= TRACK_MEMORY:
			continue
		var duplicate := false
		for k in kept:
			if k["box"].intersects(track["box"]):
				duplicate = true
				break
		if not duplicate:
			kept.append(track)
	_tracks = kept


## One person: keypoints from RTMPose, distance from the depth camera.
func _person_from_box(image: Image, box: Rect2) -> Dictionary:
	var kps: PackedVector3Array = _pose.infer(image, box)
	if kps.size() < 17:
		return {}
	var score_sum := 0.0
	var best := 0.0
	for k in kps:
		score_sum += k.z
		best = maxf(best, k.z)
	var mean_score := score_sum / float(kps.size())
	var wrists: float = minf(kps[COCO_LEFT_WRIST].z, kps[COCO_RIGHT_WRIST].z)
	if _log and Time.get_ticks_msec() / 1000.0 > _log_next:
		_log_next = Time.get_ticks_msec() / 1000.0 + 1.0
		print("rtm box %s  mean=%.3f best=%.3f wrists=%.3f  nose=(%.0f,%.0f) hipL=(%.0f,%.0f)" % [
			box, mean_score, best, wrists,
			kps[0].x, kps[0].y, kps[COCO_HIPS[0]].x, kps[COCO_HIPS[0]].y])
	if mean_score < min_score:
		return {}

	# Torso first: it is the depth every uncertain limb falls back to.
	var torso_samples: Array[float] = []
	for i in COCO_SHOULDERS + COCO_HIPS:
		var d := _depth_at(kps[i], false)
		if d > 0.0:
			torso_samples.append(d)
	if torso_samples.is_empty():
		if _log:
			print("rtm: no depth under the torso keypoints")
		return {}
	torso_samples.sort()
	var torso_z: float = torso_samples[torso_samples.size() / 2]
	if torso_z < play_near_m or torso_z > play_far_m:
		if _log:
			print("rtm: torso depth %.2f m outside %.1f-%.1f" % [torso_z, play_near_m, play_far_m])
		return {}

	var width := float(image.get_width())
	var height := float(image.get_height())
	var landmarks: Array = []
	for i in COCO_TO_JOINT.size():
		landmarks.append(_landmark(kps[i], COCO_TO_JOINT[i], torso_z, width, height, i in NEAR_SURFACE))
	# A punch comes straight at the camera: the arm foreshortens to almost nothing in
	# the image and the wrist keypoint lands on the forearm or the torso, so the wrist's
	# own depth window sees the body. The fist is still the nearest surface along the
	# elbow-to-wrist line, extended past the wrist; use that when it is closer.
	for pair in [[COCO_LEFT_ELBOW, COCO_LEFT_WRIST, 9], [COCO_RIGHT_ELBOW, COCO_RIGHT_WRIST, 10]]:
		var lm: Dictionary = landmarks[pair[2]]
		var front := _arm_front_depth(kps[pair[0]], kps[pair[1]], width, height)
		if front > 0.0 and torso_z - front > 0.12 and absf(front - torso_z) <= arm_depth_limit_m:
			var wrist_z: float = lm["position_3d"].z
			if lm["depth_inferred"] or front < wrist_z - 0.05:
				lm["position_3d"] = _camera.deproject_pixel(lm["pixel"].x, lm["pixel"].y, front)
				lm["depth_inferred"] = false
				lm["depth_ok"] = true
		lm["depth_raw"] = front
	# COCO has no fingers; the game's index joints follow the wrists so that
	# anything reading them gets something sane rather than the origin.
	landmarks.append(_landmark(kps[COCO_LEFT_WRIST], 19, torso_z, width, height, true))
	landmarks.append(_landmark(kps[COCO_RIGHT_WRIST], 20, torso_z, width, height, true))

	var hips := (kps[COCO_HIPS[0]] + kps[COCO_HIPS[1]]) * 0.5
	var root: Vector3 = _camera.deproject_pixel(hips.x, hips.y, torso_z)
	return {
		"root": root,
		"landmarks": landmarks,
		"box": _box_from_keypoints(kps),
		"timestamp_ms": int(_camera.get_timestamp()),
	}


func _box_from_keypoints(kps: PackedVector3Array) -> Rect2:
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for k in kps:
		if k.z < 0.1:
			continue
		min_p = min_p.min(Vector2(k.x, k.y))
		max_p = max_p.max(Vector2(k.x, k.y))
	if min_p.x > max_p.x:
		return Rect2()
	var box := Rect2(min_p, max_p - min_p)
	# Generous padding, because a box that eases into place is by definition
	# behind a fast-moving player and must still contain all of them.
	return box.grow(maxf(box.size.x, box.size.y) * 0.24)


func _landmark(kp: Vector3, joint_index: int, torso_z: float, width: float, height: float,
		near_surface: bool) -> Dictionary:
	var depth := _depth_at(kp, near_surface)
	var inferred := false
	# A limb cannot be most of a metre off the torso: that reading is the room.
	if depth <= 0.0 or absf(depth - torso_z) > arm_depth_limit_m:
		depth = torso_z
		inferred = true
	return {
		"index": joint_index,
		"normalized": Vector2(kp.x / width, kp.y / height),
		"pixel": Vector2(kp.x, kp.y),
		"position_3d": _camera.deproject_pixel(kp.x, kp.y, depth),
		"visibility": kp.z,
		"presence": kp.z,
		"depth_ok": not inferred,
		"depth_inferred": inferred,
	}


## Nearest surface along the forearm, from the elbow through the wrist and 60 percent
## beyond it (where the fist is), sampled every few pixels with a small window.
func _arm_front_depth(elbow: Vector3, wrist: Vector3, width: float, height: float) -> float:
	if wrist.z <= 0.1:
		return 0.0
	var a := Vector2(elbow.x, elbow.y)
	var b := Vector2(wrist.x, wrist.y)
	if elbow.z <= 0.1 or a.distance_to(b) < 4.0:
		a = b - Vector2(0, 20)
	var best := 0.0
	for i in 9:
		var t := 0.4 + i * 0.15   # 0.4 .. 1.6 along elbow->wrist
		var pt := a.lerp(b, t)
		if pt.x < 0 or pt.y < 0 or pt.x >= width or pt.y >= height:
			continue
		var d: float = _camera.get_depth_percentile(int(pt.x), int(pt.y), 3, 0.15)
		if d > 0.0 and (best == 0.0 or d < best):
			best = d
	return best


func _depth_at(kp: Vector3, near_surface: bool) -> float:
	if kp.z <= 0.0:
		return 0.0
	if near_surface:
		return _camera.get_depth_percentile(int(kp.x), int(kp.y), sample_radius + 1, 0.25)
	return _camera.get_depth_at(int(kp.x), int(kp.y), sample_radius)


## Matches the MediaPipe processor's API; RTMPose is per person, so this only
## changes how many boxes are handed to it.
func set_num_poses(n: int) -> bool:
	num_poses = maxi(n, 1)
	return true
