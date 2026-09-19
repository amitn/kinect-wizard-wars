extends SceneTree
## Headless test of tracking WITHOUT a depth camera: a synthetic adult is
## projected into a 640x480 webcam image, run through the same code a real
## webcam frame takes after RTMPose (RtmPoseProcessor._person_from_size ->
## BodyTracker -> GestureDetector), and the distance and gestures are checked.
##
##   godot --headless --path game --script res://tests/rgb_pose_test.gd -- --no-camera --no-save
##
## Exit code 0 when everything passes. No extension, camera or model needed.

const W := 640.0
const H := 480.0
const FOV_DEG := 62.0
const CAMERA_HEIGHT_M := 1.0
const FPS := 30.0

# A 1.70 m adult, metres, y up from the floor. x is the person's own left/right
# as the camera sees them (the person's left is at +x in the image).
const SHOULDER_Y := 1.40
const HIP_Y := 0.91
const HALF_SHOULDERS := 0.175
const HALF_HIPS := 0.10
const UPPER_ARM := 0.30
const FOREARM := 0.25

var _focal := 0.0
var _failures := 0
var _fired: Array[String] = []


## Stands in for WebcamCamera: intrinsics and deprojection, no pixels.
class FakeWebcam extends Node:
	var focal := 0.0
	func has_depth() -> bool: return false
	func get_intrinsics() -> PackedFloat32Array: return PackedFloat32Array([focal, focal, W * 0.5, H * 0.5])
	func get_timestamp() -> float: return Time.get_ticks_msec()
	func deproject_pixel(x: float, y: float, depth_m: float) -> Vector3:
		return Vector3((x - W * 0.5) / focal * depth_m, -(y - H * 0.5) / focal * depth_m, depth_m)


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


## World point (x right, y up from the floor, z away from the camera) -> keypoint (px, py, score).
func _project(p: Vector3, score: float = 0.9) -> Vector3:
	return Vector3(W * 0.5 + p.x / p.z * _focal, H * 0.5 - (p.y - CAMERA_HEIGHT_M) / p.z * _focal, score)


## COCO-17 keypoints of the adult standing at `distance`, `offset_x` to the side.
## `right_arm` / `left_arm` are unit directions of the whole (straight) arm.
func _person(distance: float, offset_x: float, left_arm: Vector3, right_arm: Vector3) -> PackedVector3Array:
	var kps := PackedVector3Array()
	kps.resize(17)
	var c := Vector3(offset_x, 0.0, distance)
	var head := c + Vector3(0, 1.58, 0)
	kps[0] = _project(head)
	kps[1] = _project(head + Vector3(0.03, 0.03, 0))
	kps[2] = _project(head + Vector3(-0.03, 0.03, 0))
	kps[3] = _project(head + Vector3(0.075, 0.0, 0.05))
	kps[4] = _project(head + Vector3(-0.075, 0.0, 0.05))
	var sides := [[5, 7, 9, 11, 13, 15, 1.0, left_arm], [6, 8, 10, 12, 14, 16, -1.0, right_arm]]
	for side in sides:
		var sign_x: float = side[6]
		var arm: Vector3 = side[7]
		var shoulder := c + Vector3(sign_x * HALF_SHOULDERS, SHOULDER_Y, 0)
		var hip := c + Vector3(sign_x * HALF_HIPS, HIP_Y, 0)
		kps[side[0]] = _project(shoulder)
		kps[side[1]] = _project(shoulder + arm * UPPER_ARM)
		kps[side[2]] = _project(shoulder + arm * (UPPER_ARM + FOREARM))
		kps[side[3]] = _project(hip)
		kps[side[4]] = _project(hip + Vector3(0, -0.42, 0))
		kps[side[5]] = _project(hip + Vector3(0, -0.83, 0))
	return kps


func _run() -> void:
	_focal = (W * 0.5) / tan(deg_to_rad(FOV_DEG) * 0.5)
	var webcam := FakeWebcam.new()
	webcam.focal = _focal
	root.add_child(webcam)
	var processor := RtmPoseProcessor.new()
	processor._camera = webcam
	processor._has_depth = false
	var image := Image.create(int(W), int(H), false, Image.FORMAT_RGB8)
	var tracker: Node = root.get_node("/root/BodyTracker")
	tracker.gestures.forward_scale = 0.75   # what BodyTracker sets for a webcam
	tracker.gesture.connect(func(_player, gesture_name: String): _fired.append(gesture_name))

	var down := Vector3(0, -1, 0)
	var at_camera := Vector3(0, 0, -1)
	var sweep_from := Vector3(0.75, -0.1, -0.65).normalized()
	var sweep_to := Vector3(-0.75, -0.1, -0.65).normalized()
	var up_left := Vector3(0.3, 1, 0).normalized()
	var up_right := Vector3(-0.3, 1, 0).normalized()

	# 1. Distance from size, standing still at three distances.
	for distance in [1.5, 2.5, 3.5]:
		var person: Dictionary = processor._person_from_size(_person(distance, 0.0, down, down), image, {})
		var z: float = person["root"].z if not person.is_empty() else 0.0
		_check(not person.is_empty() and absf(z - distance) / distance < 0.12, "distance %.1f m estimated as %.2f m" % [distance, z])

	# 2. Reach toward the camera: nothing with the arm down, most of the arm when it points at the lens.
	var body := {}
	var rest: Dictionary = processor._person_from_size(_person(2.5, 0.0, down, down), image, body)
	var rest_reach: float = rest["landmarks"][5]["position_3d"].z - rest["landmarks"][10]["position_3d"].z
	_check(absf(rest_reach) < 0.06, "arm hanging: reach %.2f m (none expected)" % rest_reach)
	var out: Dictionary = processor._person_from_size(_person(2.5, 0.0, down, at_camera), image, body)
	var out_reach: float = out["landmarks"][6]["position_3d"].z - out["landmarks"][10]["position_3d"].z
	_check(out_reach > 0.35, "arm pointed at the lens: reach %.2f m of %.2f" % [out_reach, UPPER_ARM + FOREARM])
	var half := down.lerp(at_camera, 0.5).normalized()
	var mid: Dictionary = processor._person_from_size(_person(2.5, 0.0, down, half), image, body)
	var mid_reach: float = mid["landmarks"][6]["position_3d"].z - mid["landmarks"][10]["position_3d"].z
	_check(mid_reach > 0.2 and mid_reach < out_reach, "arm at 45 degrees: reach %.2f m, between the two" % mid_reach)

	# 3. An unsure wrist (hand out of frame) gives no reach and an invalid hand.
	var unsure := _person(2.5, 0.0, down, at_camera)
	unsure[10].z = 0.3
	var hidden: Dictionary = processor._person_from_size(unsure, image, body)
	_check(hidden["landmarks"][10]["visibility"] < 0.3 and hidden["landmarks"][10]["depth_inferred"], "low-confidence wrist is not evidence of a punch")

	# 4. Upper body only (at a desk): still a player, measured by the shoulders.
	var desk := _person(0.9, 0.0, down, down)
	for i in range(11, 17):
		desk[i].z = 0.05
	var seated: Dictionary = processor._person_from_size(desk, image, {})
	_check(not seated.is_empty() and absf(seated["root"].z - 0.9) < 0.15, "hips out of view: distance %.2f m from shoulder width" % (seated["root"].z if not seated.is_empty() else 0.0))

	# 5. Gestures over time, in real time because BodyTracker stamps frames with the clock.
	body = {}
	var script := [
		# [seconds, left arm from, left arm to, right arm from, right arm to]
		[1.0, down, down, down, down],                         # settle: nothing may fire
		[0.2, down, down, down, at_camera],                    # right punch
		[0.4, down, down, at_camera, down],
		[0.6, down, down, down, down],
		[0.3, down, sweep_from, down, down],                   # wind up: left arm out to the side
		[0.3, sweep_from, sweep_to, down, down],               # ...and across the body at chest height
		[0.3, sweep_to, down, down, down],
		[0.6, down, down, down, down],
		[0.4, down, up_left, down, up_right],                  # both hands up
		[0.4, up_left, up_left, up_right, up_right],
	]
	var fired_while_still := -1
	var started := Time.get_ticks_msec()
	for step in script:
		var frames := int(float(step[0]) * FPS)
		for f in frames:
			var t := float(f + 1) / float(frames)
			var left: Vector3 = (step[1] as Vector3).slerp(step[2], t)
			var right: Vector3 = (step[3] as Vector3).slerp(step[4], t)
			var person: Dictionary = processor._person_from_size(_person(2.5, 0.0, left, right), image, body)
			body = person["body"]
			tracker._on_poses([person], Time.get_ticks_msec())
			if OS.get_cmdline_user_args().has("--trace"):
				var pl: TrackedPlayer = tracker.players[0]
				var sh := (pl.left_shoulder.raw_position + pl.right_shoulder.raw_position) * 0.5
				print("  t=%.2f L fwd=%.2f v=(%+.1f,%+.1f) x=%.2f   R fwd=%.2f v=(%+.1f,%+.1f)   %s" % [(Time.get_ticks_msec() - started) / 1000.0,
					sh.z - pl.left_hand.raw_position.z, pl.left_hand.velocity.x, pl.left_hand.velocity.z, pl.left_hand.raw_position.x,
					sh.z - pl.right_hand.raw_position.z, pl.right_hand.velocity.x, pl.right_hand.velocity.z, " ".join(_fired)])
			await create_timer(1.0 / FPS).timeout
		if fired_while_still < 0:
			fired_while_still = _fired.size()   # after the first step, which only stands
	print("gestures fired: %s  (%.1f s)" % [", ".join(_fired), (Time.get_ticks_msec() - started) / 1000.0])
	_check(fired_while_still == 0, "standing still fires nothing")
	_check("punch_right" in _fired, "a punch at the lens fires punch_right")
	_check(not ("punch_left" in _fired), "the other hand does not punch")
	_check("swipe_left" in _fired, "a sweep across the body fires a swipe, on the stroke and not the wind-up")
	_check("arms_up" in _fired, "both hands above the head fires arms_up")

	print("ALL PASSED" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
