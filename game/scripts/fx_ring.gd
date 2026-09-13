class_name FXRing
extends Node2D
## A short-lived expanding rune ring: used for casts, hits and clashes.

var color := Color.WHITE
var life := 0.5
var radius_start := 20.0
var radius_end := 160.0
var thickness := 6.0
var ticks := 24
var squash := 1.0   # < 1 flattens it into a floor ring

var _age := 0.0


static func spawn(parent: Node, at: Vector2, c: Color, r_end: float = 160.0, life_s: float = 0.5, squash_y: float = 1.0) -> FXRing:
	var ring := FXRing.new()
	ring.position = at
	ring.color = c
	ring.radius_end = r_end
	ring.life = life_s
	ring.squash = squash_y
	parent.add_child(ring)
	return ring


func _process(delta: float) -> void:
	_age += delta
	if _age >= life:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var f := clampf(_age / life, 0.0, 1.0)
	var e := 1.0 - pow(1.0 - f, 3.0)
	var r := lerpf(radius_start, radius_end, e)
	var c := color
	c.a = (1.0 - f) * 0.9
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, squash))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, c, thickness * (1.0 - f * 0.6), true)
	c.a *= 0.5
	draw_arc(Vector2.ZERO, r * 0.8, 0.0, TAU, 48, c, 2.0, true)
	var spin := _age * 3.0
	for i in ticks:
		var a := spin + i * TAU / ticks
		var len := 14.0 if i % 4 == 0 else 6.0
		draw_line(Vector2.from_angle(a) * (r - len), Vector2.from_angle(a) * (r + 2.0), c, 2.0, true)
	draw_set_transform(Vector2.ZERO)
