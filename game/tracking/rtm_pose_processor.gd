class_name RtmPoseProcessor
extends RefCounted
## RTMPose in place of MediaPipe, with the same output contract.
##
## A drop-in alternative to pose_processor.gd: it emits the same `poses_ready`
## people, so BodyTracker, TrackedPlayer and every game above them are unchanged
## and cannot tell which one is running.
##
## It runs on either camera. With a depth camera (OrbbecCamera) every keypoint
## gets its distance from the depth image. With a plain webcam (WebcamCamera)
## there is no depth, so distance is estimated from how large the person
## appears - see _person_from_size().
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
var upper_min_score := 0.6    # RGB only: a confident face and shoulders pass when the rest of the body is out of view
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

# RGB only (no depth camera): distances come from the apparent size of a
# reference adult, so everyone measures as one - a child reads as an adult
# standing further back, which is what height-scaled gesture thresholds want.
const REF_TORSO_M := 0.49        # shoulder line to hip line
const REF_SHOULDERS_M := 0.35
const REF_THIGH_M := 0.42
const REF_SHIN_M := 0.41
const REF_UPPER_ARM_M := 0.30
const REF_FOREARM_M := 0.25
const ARM_DEAD_BAND_M := 0.05    # reach below this is keypoint jitter on a fully visible arm
const ARM_SCALE_MIN := 0.85      # how far a player's arms may differ from the reference
const ARM_SCALE_MAX := 1.2
const SIZE_SMOOTHING := 0.2      # how fast the estimated distance follows a new reading
const ARM_MIN_SCORE := 0.45      # a wrist the model is unsure of is not evidence of a punch
var rgb_near_m := 0.4            # a webcam player may sit at a desk
var rgb_far_m := 6.0

var _camera: Node
var _has_depth := true
var _pose = null               # RtmPose, from the extension
var _last_frame_id := -1
var _log := false
var _log_next := 0.0
var _tracks: Array = []        # [{box: Rect2, seen: float, body: Dictionary}] - people we are following
var _scan := 0                 # which candidate crop to sweep next
const SCAN_COLUMNS := 4
const TRACK_MEMORY := 0.6      # seconds a track survives without being confirmed
const BOX_SMOOTHING := 0.2     # how fast the crop follows the keypoints it found
var _result_times: Array[float] = []


func setup(camera: Node) -> bool:
	if _pose == null and not load_model():
		return false
	set_camera(camera)
	return available


## Points the processor at a camera (OrbbecCamera or WebcamCamera), or at
## nothing. The model stays loaded, so switching cameras costs nothing.
func set_camera(camera: Node) -> void:
	_camera = camera
	_tracks.clear()
	_last_frame_id = -1
	_has_depth = false
	if camera != null:
		_has_depth = camera.has_depth() if camera.has_method("has_depth") else camera.has_method("get_depth_percentile")
	available = _pose != null and camera != null


func load_model() -> bool:
	available = false
	if not ClassDB.class_exists("RtmPose"):
		last_error = "RtmPose not in the extension (build with onnxruntime=<dir>)"
		return false
	if not FileAccess.file_exists(MODEL_PATH):
		last_error = "model missing: " + MODEL_PATH + " (tools/fetch_rtmpose_model.sh)"
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
		var person := _person_from_box(image, box, _body_of(box))
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
		found.append({"box": person["box"], "body": person["body"]})
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
		var turn := _scan % (SCAN_COLUMNS + 1)
		_scan += 1
		var candidate := Rect2(step * float(turn), 0.0, slice_w, float(height))
		if turn == SCAN_COLUMNS:
			# After the slices, the whole frame: somebody close fills more than a slice.
			candidate = Rect2(0.0, 0.0, float(width), float(height))
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
	for entry in found:
		# Ease the box toward the new keypoints instead of snapping to them. The
		# crop decides what the model sees, so a box that chases every frame's
		# jitter feeds that jitter straight back into the keypoints it came from.
		var box: Rect2 = entry["box"]
		var smoothed: Rect2 = box
		for track in _tracks:
			var previous: Rect2 = track["box"]
			if previous.intersects(box):
				smoothed = Rect2(previous.position.lerp(box.position, BOX_SMOOTHING),
						previous.size.lerp(box.size, BOX_SMOOTHING))
				break
		kept.append({"box": smoothed, "seen": now_s, "body": entry["body"]})
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


## What is remembered about the person a candidate box follows (their smoothed
## size and arm length, RGB only). A sweep box follows nobody yet.
func _body_of(box: Rect2) -> Dictionary:
	for track in _tracks:
		if track["box"] == box:
			return track.get("body", {})
	return {}


## One person: keypoints from RTMPose, distance from the depth camera - or from
## their apparent size when the camera has no depth.
func _person_from_box(image: Image, box: Rect2, body: Dictionary) -> Dictionary:
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
		# Somebody close to a webcam, or sitting at a desk, shows only head and
		# shoulders: the missing legs drag the whole-body mean under the bar. A
		# depth camera needs its full-body view anyway, so this is for RGB only.
		if _has_depth or _upper_body_score(kps) < upper_min_score:
			return {}
	if not _has_depth:
		return _person_from_size(kps, image, body)

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
		"body": body,
		"timestamp_ms": int(_camera.get_timestamp()),
	}


## RGB only. Three estimates stand in for the depth image:
##   - distance: a body segment of known length L that spans p pixels is
##     focal * L / p away. Foreshortening only ever makes a segment look
##     shorter, so the truth is near the longest reading; the second longest is
##     used so one bad keypoint cannot pull the player forward.
##   - the body: every joint sits on the plane at that distance.
##   - the arms: an arm pointed at the camera shrinks toward a dot, so each
##     segment's reach toward the lens is sqrt(L^2 - seen^2). That is the signal
##     a punch needs, and the gesture detector reads it exactly like real depth.
func _person_from_size(kps: PackedVector3Array, image: Image, body: Dictionary) -> Dictionary:
	for i in COCO_SHOULDERS:
		if kps[i].z < 0.3:
			return {}
	var shoulders := (kps[COCO_SHOULDERS[0]] + kps[COCO_SHOULDERS[1]]) * 0.5
	var hips := (kps[COCO_HIPS[0]] + kps[COCO_HIPS[1]]) * 0.5
	var hips_seen: bool = kps[COCO_HIPS[0]].z > 0.3 and kps[COCO_HIPS[1]].z > 0.3
	if hips_seen:
		var spine := Vector2(hips.x - shoulders.x, hips.y - shoulders.y)
		# Players stand; a torso lying across the image is a sofa cushion or a poster.
		if spine.y < spine.length() * 0.6:
			return {}
	var px_per_m := _pixels_per_meter(kps, hips_seen)
	var intrinsics: PackedFloat32Array = _camera.get_intrinsics()
	if px_per_m <= 0.0 or intrinsics.size() < 1 or intrinsics[0] <= 0.0:
		return {}
	if body.has("px_per_m"):
		px_per_m = lerpf(body["px_per_m"], px_per_m, SIZE_SMOOTHING)
	var torso_z: float = intrinsics[0] / px_per_m
	if torso_z < rgb_near_m or torso_z > rgb_far_m:
		if _log:
			print("rtm: estimated distance %.2f m outside %.1f-%.1f" % [torso_z, rgb_near_m, rgb_far_m])
		return {}
	body = body.duplicate()
	body["px_per_m"] = px_per_m
	if not hips_seen:
		# Somebody close, or sitting at a desk: only the upper body is in view. The
		# hips go where a torso's length below the shoulders puts them.
		hips = shoulders + Vector3(0.0, REF_TORSO_M * px_per_m, 0.0)

	var width := float(image.get_width())
	var height := float(image.get_height())
	var landmarks: Array = []
	for i in COCO_TO_JOINT.size():
		landmarks.append(_flat_landmark(kps[i], COCO_TO_JOINT[i], torso_z, width, height))

	var arm_scale := _arm_scale(body, kps, landmarks)
	for arm in [[5, COCO_LEFT_ELBOW, COCO_LEFT_WRIST], [6, COCO_RIGHT_ELBOW, COCO_RIGHT_WRIST]]:
		var shoulder: Dictionary = landmarks[arm[0]]
		var elbow: Dictionary = landmarks[arm[1]]
		var wrist: Dictionary = landmarks[arm[2]]
		# Reach needs a wrist the model is sure of: with the hands out of frame it
		# still reports wrists, low in confidence and jumping about, and their
		# "foreshortening" is noise. The elbow may be half hidden behind the fist.
		var arm_seen: bool = kps[arm[2]].z >= ARM_MIN_SCORE and kps[arm[1]].z >= 0.25
		var upper := _reach_toward_camera(shoulder["position_3d"], elbow["position_3d"], REF_UPPER_ARM_M * arm_scale) if arm_seen else 0.0
		var fore := _reach_toward_camera(elbow["position_3d"], wrist["position_3d"], REF_FOREARM_M * arm_scale) if arm_seen else 0.0
		elbow["position_3d"] = _camera.deproject_pixel(elbow["pixel"].x, elbow["pixel"].y, torso_z - upper)
		wrist["position_3d"] = _camera.deproject_pixel(wrist["pixel"].x, wrist["pixel"].y, torso_z - upper - fore)
		wrist["depth_inferred"] = not arm_seen
		wrist["depth_raw"] = torso_z - upper - fore
		if not arm_seen:
			# Below the tracker's validity bar, so no gesture is read from this hand.
			wrist["visibility"] = minf(wrist["visibility"], 0.29)
			wrist["presence"] = wrist["visibility"]
	for pair in [[COCO_LEFT_WRIST, 19], [COCO_RIGHT_WRIST, 20]]:
		var finger: Dictionary = landmarks[pair[0]].duplicate()
		finger["index"] = pair[1]
		landmarks.append(finger)

	return {
		"root": _camera.deproject_pixel(hips.x, hips.y, torso_z),
		"landmarks": landmarks,
		"box": _box_from_keypoints(kps),
		"body": body,
		"timestamp_ms": int(_camera.get_timestamp()),
	}


## How many pixels a metre spans at the player's distance, from the body
## segments whose both ends are confidently seen.
func _pixels_per_meter(kps: PackedVector3Array, hips_seen: bool) -> float:
	var readings: Array[float] = [_span(kps[COCO_SHOULDERS[0]], kps[COCO_SHOULDERS[1]]) / REF_SHOULDERS_M]
	if not hips_seen:
		return readings[0]
	var shoulders := (kps[COCO_SHOULDERS[0]] + kps[COCO_SHOULDERS[1]]) * 0.5
	var hips := (kps[COCO_HIPS[0]] + kps[COCO_HIPS[1]]) * 0.5
	readings.append(Vector2(shoulders.x - hips.x, shoulders.y - hips.y).length() / REF_TORSO_M)
	for leg in [[11, 13, 15], [12, 14, 16]]:   # hip, knee, ankle
		if kps[leg[0]].z > 0.4 and kps[leg[1]].z > 0.4:
			readings.append(_span(kps[leg[0]], kps[leg[1]]) / REF_THIGH_M)
		if kps[leg[1]].z > 0.4 and kps[leg[2]].z > 0.4:
			readings.append(_span(kps[leg[1]], kps[leg[2]]) / REF_SHIN_M)
	readings.sort()
	return readings[-2] if readings.size() >= 3 else readings[-1]


func _span(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.y - b.y).length()


## The player's arm length against the reference adult's: the 90th percentile of
## the longest arm segment seen over the last few seconds (an arm is at its true
## length whenever it lies across the image, which happens all the time).
func _arm_scale(body: Dictionary, kps: PackedVector3Array, landmarks: Array) -> float:
	var ratios: Array = body.get("arm_ratios", []).duplicate()
	var longest := 0.0
	for segment in [[5, 7, REF_UPPER_ARM_M], [6, 8, REF_UPPER_ARM_M], [7, 9, REF_FOREARM_M], [8, 10, REF_FOREARM_M]]:
		if kps[segment[0]].z < 0.5 or kps[segment[1]].z < 0.5:
			continue
		var a: Vector3 = landmarks[segment[0]]["position_3d"]
		var b: Vector3 = landmarks[segment[1]]["position_3d"]
		longest = maxf(longest, Vector2(a.x - b.x, a.y - b.y).length() / float(segment[2]))
	if longest > 0.6:
		ratios.append(minf(longest, ARM_SCALE_MAX))
		if ratios.size() > 150:
			ratios.pop_front()
	body["arm_ratios"] = ratios
	if ratios.size() < 15:
		return 1.0
	var sorted := ratios.duplicate()
	sorted.sort()
	return clampf(sorted[int(sorted.size() * 0.9)], ARM_SCALE_MIN, ARM_SCALE_MAX)


## How far toward the camera a limb segment of real length `length_m` must
## point to look as short as it does between a and b.
func _reach_toward_camera(a: Vector3, b: Vector3, length_m: float) -> float:
	var seen := Vector2(a.x - b.x, a.y - b.y).length()
	var ratio := clampf(seen / length_m, 0.0, 1.0)
	return maxf(0.0, length_m * sqrt(1.0 - ratio * ratio) - ARM_DEAD_BAND_M)


func _flat_landmark(kp: Vector3, joint_index: int, depth: float, width: float, height: float) -> Dictionary:
	return {
		"index": joint_index,
		"normalized": Vector2(kp.x / width, kp.y / height),
		"pixel": Vector2(kp.x, kp.y),
		"position_3d": _camera.deproject_pixel(kp.x, kp.y, depth),
		"visibility": kp.z,
		"presence": kp.z,
		"depth_ok": true,
		"depth_inferred": false,
	}


## Mean confidence of the nose, eyes, ears and shoulders.
func _upper_body_score(kps: PackedVector3Array) -> float:
	var sum := 0.0
	for i in 7:
		sum += kps[i].z
	return sum / 7.0


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
