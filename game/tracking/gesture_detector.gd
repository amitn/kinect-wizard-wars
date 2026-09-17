class_name GestureDetector
extends RefCounted
## Deterministic gestures from joint positions and velocities. All thresholds
## are tunable; distances in meters, speeds in meters per second.

var push_speed := 1.6          # hand moving toward the camera (negative z velocity)
var push_min_reach := 0.30     # hand must end up this far in front of the shoulders
var punch_cooldown := 0.5
var swipe_speed := 1.8         # sideways hand speed
var swipe_min_travel := 0.45   # meters within the window
var swipe_cooldown := 1.0
var hands_together_dist := 0.18
var crouch_ratio := 0.75       # hips lower than this fraction of the standing hip height
var jump_speed := 1.2          # body root rising this fast

var _last: Dictionary = {}     # "id:gesture" -> time
var _swipe_hist: Dictionary = {}  # "id:side" -> Array of [t, x]
var _streak: Dictionary = {}   # "id:state" -> consecutive updates the state held
const STATE_PERSIST := 4       # updates a crouch/jump must hold before it counts


func _held(key: String, cond: bool) -> bool:
	_streak[key] = (int(_streak.get(key, 0)) + 1) if cond else 0
	return int(_streak[key]) >= STATE_PERSIST


func _cool(key: String, now: float, cooldown: float) -> bool:
	if _last.has(key) and now - float(_last[key]) < cooldown:
		return false
	_last[key] = now
	return true


## Returns the gestures that fired this frame and updates derived state on the player.
func update(p: TrackedPlayer, now: float) -> Array[String]:
	var fired: Array[String] = []
	var shoulders := p.shoulder_center()
	var head := p.head.position_3d
	# Shorter players have shorter arms: scale the distance and speed thresholds.
	var reach := clampf(p.standing_height / 1.7, 0.6, 1.1) if p.standing_height > 0.0 else 1.0

	# Arms up: both wrists above the head.
	p.arms_up = p.left_hand.valid and p.right_hand.valid \
		and p.left_hand.position_3d.y > head.y and p.right_hand.position_3d.y > head.y

	# Hands together: true 3D distance.
	p.hands_together = p.left_hand.valid and p.right_hand.valid \
		and p.left_hand.position_3d.distance_to(p.right_hand.position_3d) < hands_together_dist

	# Push / punch: fast motion toward the camera ending well in front of the shoulders.
	for side in ["left", "right"]:
		var hand: TrackedJoint = p.joint(side + "_wrist")
		if not hand.valid:
			continue
		var forward := shoulders.z - hand.position_3d.z
		if hand.velocity.z < -push_speed * reach and forward > push_min_reach * reach:
			if _cool("%d:punch_%s" % [p.id, side], now, punch_cooldown):
				fired.append("punch_" + side)
		# Swipe: sideways travel over the last 0.4 s at chest height, in front of the body.
		var key := "%d:%s" % [p.id, side]
		var hist: Array = _swipe_hist.get(key, [])
		hist.append([now, hand.position_3d.x])
		while hist.size() > 0 and now - hist[0][0] > 0.4:
			hist.pop_front()
		_swipe_hist[key] = hist
		var at_chest := absf(hand.position_3d.y - shoulders.y) < 0.35 * reach and forward > 0.1 * reach
		if hist.size() >= 3 and at_chest and absf(hand.velocity.x) > swipe_speed * reach:
			var dx: float = hist[-1][1] - hist[0][1]
			if absf(dx) > swipe_min_travel * reach and _cool("%d:swipe" % p.id, now, swipe_cooldown):
				fired.append("swipe_right" if dx > 0 else "swipe_left")
				_swipe_hist[key] = []

	# Crouch / jump from the body root.
	var crouch_now := false
	if p.standing_height > 0.0 and p.left_foot.valid and p.right_foot.valid:
		var hips_above_feet := p.position.y - minf(p.left_foot.position_3d.y, p.right_foot.position_3d.y)
		var standing_hips := p.standing_height * 0.5
		crouch_now = hips_above_feet < standing_hips * crouch_ratio
	p.is_crouching = _held("%d:crouch" % p.id, crouch_now)
	p.is_jumping = _held("%d:jump" % p.id, p.velocity.y > jump_speed)
	if p.is_jumping and _cool("%d:jump" % p.id, now, 0.8):
		fired.append("jump")
	if p.is_crouching and _cool("%d:crouch" % p.id, now, 0.8):
		fired.append("crouch")
	if p.arms_up and _cool("%d:arms_up" % p.id, now, 0.5):
		fired.append("arms_up")
	if p.hands_together and _cool("%d:hands_together" % p.id, now, 0.5):
		fired.append("hands_together")

	for g in fired:
		p.gestures[g] = now
	return fired
