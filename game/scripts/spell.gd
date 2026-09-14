class_name Spell
extends Node2D
## A projectile in flight: a quick bolt or a slow, wide wave.

enum Kind { BOLT, WAVE }

const BOLT_COST := 15.0
const WAVE_COST := 35.0

var kind: Kind = Kind.BOLT
var element := "fire"
var caster: Wizard = null
var direction := 1
var speed := 900.0
var damage := 12.0
var radius := 26.0
var half_height := 26.0
var power := 1.0
var alive := true

var _particles: CPUParticles2D
var _orb: Sprite2D = null
var _wave: Sprite2D = null


static func cost_of(spell_kind: Kind) -> float:
	return BOLT_COST if spell_kind == Kind.BOLT else WAVE_COST


static func make(spell_kind: Kind, spell_element: String, from_wizard: Wizard, origin: Vector2, dir: int) -> Spell:
	var s := Spell.new()
	s.kind = spell_kind
	s.element = spell_element
	s.caster = from_wizard
	s.direction = dir
	s.position = origin
	if spell_kind == Kind.BOLT:
		s.speed = 950.0
		s.damage = 12.0
		s.radius = 26.0
		s.half_height = 26.0
	else:
		s.speed = 420.0
		s.damage = 25.0
		s.radius = 60.0
		s.half_height = 220.0
	return s


func color() -> Color:
	return Color(1.0, 0.5, 0.15) if element == "fire" else Color(0.35, 0.7, 1.0)


func bright_color() -> Color:
	return Color(1.0, 0.9, 0.4) if element == "fire" else Color(0.85, 0.97, 1.0)


func _ready() -> void:
	_particles = CPUParticles2D.new()
	_particles.amount = 60 if kind == Kind.BOLT else 140
	_particles.lifetime = 0.45 if kind == Kind.BOLT else 0.7
	_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_particles.emission_sphere_radius = radius * 0.6 if kind == Kind.BOLT else 30.0
	if kind == Kind.WAVE:
		_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
		_particles.emission_rect_extents = Vector2(20.0, half_height)
	_particles.direction = Vector2(-direction, 0.0)
	_particles.spread = 30.0
	_particles.gravity = Vector2(0.0, -120.0 if element == "fire" else 160.0)
	_particles.initial_velocity_min = 120.0
	_particles.initial_velocity_max = 260.0
	_particles.scale_amount_min = 0.3
	_particles.scale_amount_max = 0.9
	_particles.texture = WizardFX.soft_particle_texture()
	var ramp := Gradient.new()
	ramp.set_color(0, bright_color())
	var end := color()
	end.a = 0.0
	ramp.set_color(1, end)
	_particles.color_ramp = ramp
	add_child(_particles)

	var wave_art := "res://art/%s_wave.png" % element
	if kind == Kind.WAVE and ResourceLoader.exists(wave_art):
		_wave = Sprite2D.new()
		_wave.texture = load(wave_art)
		var wmat := CanvasItemMaterial.new()
		wmat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		_wave.material = wmat
		_wave.flip_h = direction < 0
		_wave.scale = Vector2.ONE * (half_height * 2.3 / _wave.texture.get_height())
		add_child(_wave)
	var art := "res://art/%s_orb.png" % element
	if kind == Kind.BOLT and ResourceLoader.exists(art):
		_orb = Sprite2D.new()
		_orb.texture = load(art)
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		_orb.material = mat
		_orb.flip_h = direction < 0
		var target := radius * 5.0
		_orb.scale = Vector2.ONE * (target / _orb.texture.get_height())
		add_child(_orb)


func _process(delta: float) -> void:
	if not alive:
		return
	position.x += direction * speed * delta
	if _orb != null:
		var t := Time.get_ticks_msec() / 1000.0
		var k := (0.6 + 0.4 * power) * (1.0 + 0.06 * sin(t * 25.0))
		_orb.scale = Vector2.ONE * (radius * 5.0 / _orb.texture.get_height()) * k
		_orb.rotation = sin(t * 9.0) * 0.08
	if _wave != null:
		var t2 := Time.get_ticks_msec() / 1000.0
		var k2 := (0.7 + 0.3 * power) * (1.0 + 0.04 * sin(t2 * 13.0))
		_wave.scale = Vector2(1.0 + 0.05 * sin(t2 * 21.0), 1.0) * (half_height * 2.3 / _wave.texture.get_height()) * k2
	queue_redraw()


func extinguish() -> void:
	if not alive:
		return
	alive = false
	if _orb != null:
		_orb.visible = false
	if _wave != null:
		_wave.visible = false
	_particles.emitting = false
	get_tree().create_timer(_particles.lifetime).timeout.connect(queue_free)
	queue_redraw()


func _draw() -> void:
	if not alive:
		return
	var c := color()
	var b := bright_color()
	var deep := Color(1.0, 0.25, 0.05) if element == "fire" else Color(0.15, 0.45, 1.0)
	var t := Time.get_ticks_msec() / 1000.0
	if kind == Kind.BOLT:
		var r := radius * (0.6 + 0.4 * power)
		var flicker := 1.0 + 0.1 * sin(t * 23.0 + position.x * 0.05)
		if _orb != null:
			var ring0 := b
			ring0.a = 0.7
			var spin0 := t * 5.0 * direction
			for seg in 6:
				var a0 := spin0 + seg * TAU / 6.0
				draw_arc(Vector2.ZERO, r * 2.3, a0, a0 + TAU / 6.0 * 0.5, 8, ring0, 3.0, true)
			return
		# Streak behind the orb.
		for i in 6:
			var back := Vector2(-direction * (i + 1) * r * 0.9, 0.0)
			var sc := deep
			sc.a = 0.35 * (1.0 - i / 6.0)
			draw_circle(back, r * (1.0 - i * 0.13), sc)
		var outer := deep
		outer.a = 0.28
		draw_circle(Vector2.ZERO, r * 2.4 * flicker, outer)
		outer.a = 0.5
		draw_circle(Vector2.ZERO, r * 1.6 * flicker, outer)
		draw_circle(Vector2.ZERO, r * flicker, c)
		draw_circle(Vector2.ZERO, r * 0.5, b)
		# Rotating rune ring.
		var ring := b
		ring.a = 0.85
		var spin := t * 5.0 * direction
		for seg in 6:
			var a0 := spin + seg * TAU / 6.0
			draw_arc(Vector2.ZERO, r * 2.0, a0, a0 + TAU / 6.0 * 0.5, 8, ring, 3.0, true)
		for seg in 3:
			var a := -spin * 0.6 + seg * TAU / 3.0
			draw_line(Vector2.from_angle(a) * r * 1.3, Vector2.from_angle(a + TAU / 3.0) * r * 1.3, ring, 1.5, true)
	else:
		var mid := 0.0 if direction > 0 else PI
		var half := deg_to_rad(70.0)
		var r := half_height * (0.7 + 0.3 * power)
		var center := Vector2(-direction * r * 0.6, 0.0)
		if _wave != null:
			# Art wave: only the travelling rune ticks on top of the sprite.
			var ring1 := b
			ring1.a = 0.7
			var n1 := 12
			for i in n1:
				var a := mid - half + (i + fmod(t * 2.0, 1.0)) * (2.0 * half / n1)
				var p0 := center + Vector2.from_angle(a) * (r * 0.95)
				draw_line(p0, p0 + Vector2.from_angle(a) * 12.0, ring1, 2.0, true)
			return
		var outer := deep
		outer.a = 0.18
		draw_arc(center, r, mid - half, mid + half, 48, outer, 110.0, true)
		outer.a = 0.5
		draw_arc(center, r, mid - half, mid + half, 48, c, 40.0, true)
		draw_arc(center, r, mid - half, mid + half, 48, b, 8.0, true)
		# Inner glyph ring and tick marks travelling along the crescent.
		var ring := b
		ring.a = 0.8
		draw_arc(center, r * 0.72, mid - half * 0.85, mid + half * 0.85, 40, ring, 3.0, true)
		var n := 14
		for i in n:
			var a := mid - half + (i + fmod(t * 2.0, 1.0)) * (2.0 * half / n)
			var p0 := center + Vector2.from_angle(a) * (r * 0.72)
			var p1 := center + Vector2.from_angle(a) * (r * 0.72 + (18.0 if i % 2 == 0 else 9.0))
			draw_line(p0, p1, ring, 2.0, true)
		# Core glyph.
		var glyph := b
		glyph.a = 0.9
		var spin := t * 2.0
		for seg in 3:
			var a := spin + seg * TAU / 3.0
			draw_line(center + Vector2.from_angle(a) * 26.0, center + Vector2.from_angle(a + TAU / 3.0) * 26.0, glyph, 2.0, true)
		draw_arc(center, 34.0, 0.0, TAU, 24, glyph, 2.0, true)
