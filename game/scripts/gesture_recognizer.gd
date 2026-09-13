class_name GestureRecognizer
extends RefCounted
## Turns a stream of BodyData into spell events for one player.
## All positions are relative to the SpineShoulder joint, in meters.
## Tune the constants below if casting feels too easy or too hard.

signal bolt_cast(hand: String)                  # "left" or "right"
signal wave_cast(hand: String, direction: int)  # direction: -1 / +1 along camera x
signal shield_changed(active: bool)

const HISTORY_SEC := 0.6

# Bolt: a fast punch straight toward the sensor.
const BOLT_WINDOW_SEC := 0.35
const BOLT_PUSH_DIST := 0.28     # hand must travel this far toward the sensor inside the window
const BOLT_EXTEND_Z := -0.38     # ...and end up at least this far in front of the shoulders
const BOLT_REARM_Z := -0.25      # hand must come back past this before it can fire again
const BOLT_MAX_ABS_Y := 0.40     # keep it roughly at chest height
const BOLT_MAX_SIDE := 0.30      # hand stays in front of its own shoulder (a sweep wind-up does not)
const BOLT_MAX_DRIFT := 0.25     # ...and does not slide sideways during the punch
const BOLT_SPEED_WINDOW := 0.12  # a punch has almost no sideways speed; a sweep crossing the
const BOLT_MAX_SIDE_SPEED := 0.10  # shoulder line does (meters moved inside BOLT_SPEED_WINDOW)
const BOLT_COOLDOWN := 0.5

# Wave: a wide horizontal sweep in front of the body.
const WAVE_WINDOW_SEC := 0.4
const WAVE_SWEEP_DIST := 0.55
const WAVE_MIN_FRONT_Z := -0.15
const WAVE_MAX_ABS_Y := 0.35
const WAVE_COOLDOWN := 1.2

# Shield: both hands raised above the head. Hysteresis avoids flicker.
const SHIELD_ON_MARGIN := -0.05
const SHIELD_OFF_MARGIN := -0.18

var shield_active := false

var _history := {"left": [], "right": []}   # arrays of {"t": float, "p": Vector3}
var _shoulder_x := {"left": -0.2, "right": 0.2}
var _armed := {"left": true, "right": true}
var _last_bolt := {"left": -10.0, "right": -10.0}
var _last_wave := -10.0


func reset() -> void:
	_history = {"left": [], "right": []}
	_armed = {"left": true, "right": true}
	if shield_active:
		shield_active = false
		shield_changed.emit(false)


## Feed one skeleton frame. `now` is seconds on the game clock.
func update(body: BodyData, now: float) -> void:
	var origin := body.joint("SpineShoulder")
	var head_y := body.joint("Head").y - origin.y
	var hands := {
		"left": body.joint("HandLeft") - origin,
		"right": body.joint("HandRight") - origin,
	}
	# The depth camera reports no shoulder joints; assume a normal shoulder width then.
	_shoulder_x["left"] = (body.joint("ShoulderLeft") - origin).x if body.has_joint("ShoulderLeft") else -0.2
	_shoulder_x["right"] = (body.joint("ShoulderRight") - origin).x if body.has_joint("ShoulderRight") else 0.2

	for hand in ["left", "right"]:
		var h: Array = _history[hand]
		h.append({"t": now, "p": hands[hand]})
		while h.size() > 0 and now - h[0]["t"] > HISTORY_SEC:
			h.pop_front()

	var lowest_hand := minf(hands["left"].y, hands["right"].y)
	if shield_active:
		if lowest_hand < head_y + SHIELD_OFF_MARGIN:
			shield_active = false
			shield_changed.emit(false)
	elif lowest_hand > head_y + SHIELD_ON_MARGIN:
		shield_active = true
		shield_changed.emit(true)
	if shield_active:
		return

	var fired := false
	for hand in ["left", "right"]:
		if _check_bolt(hand, now):
			fired = true
	if not fired:
		_check_wave(now)


func _check_bolt(hand: String, now: float) -> bool:
	var h: Array = _history[hand]
	if h.is_empty():
		return false
	var cur: Vector3 = h[-1]["p"]
	if not _armed[hand]:
		if cur.z > BOLT_REARM_Z:
			_armed[hand] = true
		return false
	if now - _last_bolt[hand] < BOLT_COOLDOWN:
		return false
	if cur.z > BOLT_EXTEND_Z or absf(cur.y) > BOLT_MAX_ABS_Y:
		return false
	if absf(cur.x - _shoulder_x[hand]) > BOLT_MAX_SIDE:
		return false
	var past = _sample_at(h, now - BOLT_WINDOW_SEC)
	var recent = _sample_at(h, now - BOLT_SPEED_WINDOW)
	if past == null or recent == null:
		return false
	if absf(cur.x - recent.x) > BOLT_MAX_SIDE_SPEED:
		return false
	if past.z - cur.z >= BOLT_PUSH_DIST and absf(cur.x - past.x) <= BOLT_MAX_DRIFT:
		_armed[hand] = false
		_last_bolt[hand] = now
		bolt_cast.emit(hand)
		return true
	return false


func _check_wave(now: float) -> void:
	if now - _last_wave < WAVE_COOLDOWN:
		return
	for hand in ["left", "right"]:
		var h: Array = _history[hand]
		if h.is_empty():
			continue
		var cur: Vector3 = h[-1]["p"]
		if cur.z > WAVE_MIN_FRONT_Z or absf(cur.y) > WAVE_MAX_ABS_Y:
			continue
		var past = _sample_at(h, now - WAVE_WINDOW_SEC)
		if past == null:
			continue
		var dx: float = cur.x - past.x
		if absf(dx) >= WAVE_SWEEP_DIST:
			_last_wave = now
			_armed[hand] = false
			wave_cast.emit(hand, 1 if dx > 0.0 else -1)
			return


## Oldest sample at or after `t`, or null when history does not reach back that far.
func _sample_at(h: Array, t: float):
	if h.is_empty() or h[0]["t"] > t + 0.1:
		return null
	for sample in h:
		if sample["t"] >= t:
			return sample["p"]
	return h[-1]["p"]
