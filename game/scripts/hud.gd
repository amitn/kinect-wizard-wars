class_name HUD
extends Control
## Health and mana bars, round messages and bridge status. Everything is drawn
## with the fallback font so the project needs no asset files.

var center_text := ""
var sub_text := ""
var hint_text := ""
var status_text := ""

var _fire: Wizard
var _water: Wizard


func setup(fire: Wizard, water: Wizard) -> void:
	_fire = fire
	_water = water


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	if _fire != null:
		_draw_player(font, _fire, 60.0, false)
	if _water != null:
		_draw_player(font, _water, 1860.0, true)

	if center_text != "":
		_glow_text(font, Vector2(0.0, 262.0), center_text, HORIZONTAL_ALIGNMENT_CENTER, 1920.0, 110, Color(1, 1, 1, 0.97), Color(0.55, 0.35, 1.0, 0.7), 10)
	if sub_text != "":
		_glow_text(font, Vector2(0.0, 316.0), sub_text, HORIZONTAL_ALIGNMENT_CENTER, 1920.0, 34, Color(0.85, 0.85, 0.98), Color(0.4, 0.25, 0.8, 0.6), 5)
	if hint_text != "":
		draw_string(font, Vector2(0.0, 1030.0), hint_text, HORIZONTAL_ALIGNMENT_CENTER, 1920.0, 26, Color(0.75, 0.75, 0.9))
	draw_string(font, Vector2(24.0, 1064.0), status_text, HORIZONTAL_ALIGNMENT_LEFT, 1400.0, 18, Color(0.55, 0.55, 0.7))


func _glow_text(font: Font, pos: Vector2, text: String, align: int, width: float, size: int, col: Color, glow: Color, outline: int) -> void:
	draw_string_outline(font, pos, text, align, width, size, outline, glow)
	draw_string(font, pos, text, align, width, size, col)


## A slanted neon bar. `frac` fills from the outer screen edge inward.
func _neon_bar(x: float, y: float, w: float, h: float, frac: float, c: Color, right_side: bool) -> void:
	var slant := h * 0.6
	var back := Color(0.0, 0.0, 0.05, 0.7)
	var pts := PackedVector2Array([Vector2(x + slant, y), Vector2(x + w, y), Vector2(x + w - slant, y + h), Vector2(x, y + h)])
	if right_side:
		pts = PackedVector2Array([Vector2(x, y), Vector2(x + w - slant, y), Vector2(x + w, y + h), Vector2(x + slant, y + h)])
	draw_colored_polygon(pts, back)
	# Fill.
	var fw := w * clampf(frac, 0.0, 1.0)
	if fw > 2.0:
		var fx := x + w - fw if right_side else x
		var fill: PackedVector2Array
		if right_side:
			fill = PackedVector2Array([Vector2(fx, y), Vector2(fx + fw - slant, y), Vector2(fx + fw, y + h), Vector2(fx + slant, y + h)])
		else:
			fill = PackedVector2Array([Vector2(fx + slant, y), Vector2(fx + fw, y), Vector2(fx + fw - slant, y + h), Vector2(fx, y + h)])
		var glow := c
		glow.a = 0.35
		draw_colored_polygon(fill, glow)
		var inner := fill.duplicate()
		for i in inner.size():
			inner[i] = inner[i].lerp(Vector2(fx + fw * 0.5, y + h * 0.5), 0.12)
		draw_colored_polygon(inner, c)
		var hi := c.lightened(0.5)
		hi.a = 0.7
		draw_line(fill[0] + Vector2(0, 2), fill[1] + Vector2(0, 2), hi, 2.0, true)
	# Segments.
	var seg := Color(0, 0, 0, 0.35)
	for i in range(1, 10):
		var sx := x + w * i / 10.0
		draw_line(Vector2(sx + slant * 0.5, y), Vector2(sx - slant * 0.5, y + h), seg, 2.0)
	# Outline.
	var edge := c.lightened(0.3)
	edge.a = 0.9
	draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), edge, 2.0, true)


func _draw_player(font: Font, w: Wizard, edge_x: float, right_side: bool) -> void:
	var bar_w := 760.0
	var x := edge_x - bar_w if right_side else edge_x
	var c := w.color()
	var align := HORIZONTAL_ALIGNMENT_RIGHT if right_side else HORIZONTAL_ALIGNMENT_LEFT

	var name_txt := w.display_name()
	if not w.is_tracked():
		name_txt += "   (not tracked)"
	_glow_text(font, Vector2(x, 44.0), name_txt, align, bar_w, 30, c.lightened(0.35), Color(c, 0.6), 6)

	_neon_bar(x, 56.0, bar_w, 34.0, w.hp / Wizard.MAX_HP, c, right_side)
	var mana_c := Color(0.7, 0.5, 1.0)
	_neon_bar(x + 20.0, 98.0, bar_w - 40.0, 14.0, w.mana / Wizard.MAX_MANA, mana_c, right_side)

	if w.shield_up:
		_glow_text(font, Vector2(x, 140.0), "SHIELD", align, bar_w, 24, c.lightened(0.5), Color(c, 0.7), 5)
