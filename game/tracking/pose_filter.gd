class_name PoseFilter
extends RefCounted
## One Euro filter for a Vector3: little jitter at rest, little lag when moving.
## (Casiez et al., 2012.) One instance per joint.

var min_cutoff := 1.5     # Hz; lower = smoother at rest
var beta := 0.05          # speed coefficient; higher = less lag when moving
var d_cutoff := 1.0

var _prev := Vector3.ZERO
var _prev_deriv := Vector3.ZERO
var _prev_t := -1.0
var _initialized := false


func reset() -> void:
	_initialized = false


static func _alpha(cutoff: float, dt: float) -> float:
	var tau := 1.0 / (TAU * cutoff)
	return 1.0 / (1.0 + tau / dt)


func filter(x: Vector3, t: float) -> Vector3:
	if not _initialized or t <= _prev_t:
		_prev = x
		_prev_deriv = Vector3.ZERO
		_prev_t = t
		_initialized = true
		return x
	var dt := maxf(t - _prev_t, 1e-3)
	var deriv := (x - _prev) / dt
	var a_d := _alpha(d_cutoff, dt)
	var deriv_hat := _prev_deriv.lerp(deriv, a_d)
	var cutoff := min_cutoff + beta * deriv_hat.length()
	var a := _alpha(cutoff, dt)
	var x_hat := _prev.lerp(x, a)
	_prev = x_hat
	_prev_deriv = deriv_hat
	_prev_t = t
	return x_hat


func derivative() -> Vector3:
	return _prev_deriv
