extends Node2D
## Round flow, player-to-body assignment, spell spawning and collisions.
##
## Debug keys (no camera needed):
##   Fire wizard:  Q bolt   W wave   E toggle shield
##   Water wizard: I bolt   O wave   P toggle shield
##   Enter start a round with untracked players, R restart, B re-learn the empty room,
##   D toggle the tracker debug overlay.

enum State { WAITING, COUNTDOWN, FIGHT, OVER }

const MIRROR := true               # flip if players appear on the wrong side
const COUNTDOWN_SEC := 3.5
const RESTART_HOLD_SEC := 1.5      # both players hold the shield pose this long to rematch
const HIT_MARGIN := 70.0

# Elemental edges. Fire boils water's shield; water snuffs fire's bolts.
const SHIELD_DRAIN_FIRE_VS_WATER := 25.0
const SHIELD_DRAIN_WATER_VS_FIRE := 10.0
const SHIELD_DRAIN_WAVE := 40.0
const CLASH_WATER_BOLT_SURVIVES_AT := 0.5
const CLASH_WAVE_POWER_LOSS := 0.35

@onready var fire: Wizard = $FireWizard
@onready var water: Wizard = $WaterWizard
@onready var spells_root: Node2D = $Spells
@onready var hud: HUD = $HUD

var state: State = State.WAITING
var countdown := 0.0
var winner: Wizard = null
var restart_hold := 0.0

var _spells: Array[Spell] = []
var _arena: ColorRect
var _arena_mat: ShaderMaterial
var _shake := 0.0
var _fire_energy := 0.0
var _water_energy := 0.0
var _dim: ColorRect
var _flash: ColorRect
var _debug: DebugOverlay

# Debug: `godot --path game -- --screenshots=<dir>` saves the viewport every
# SHOT_INTERVAL seconds for SHOT_COUNT shots, then quits.
const SHOT_INTERVAL := 2.0
const SHOT_COUNT := 10
var _shot_dir := ""
var _shot_count := SHOT_COUNT


func _ready() -> void:
	_arena = ColorRect.new()
	_arena.size = Vector2(1920, 1080)
	_arena.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arena_mat = ShaderMaterial.new()
	_arena_mat.shader = preload("res://shaders/arena.gdshader")
	_arena_mat.set_shader_parameter("noise_tex", WizardFX.noise_texture())
	_arena_mat.set_shader_parameter("horizon", (Wizard.GROUND_Y + 10.0) / 1080.0)
	if ResourceLoader.exists("res://art/arena_backdrop.png"):
		_arena_mat.set_shader_parameter("backdrop_tex", load("res://art/arena_backdrop.png"))
		_arena_mat.set_shader_parameter("use_backdrop", 1.0)
	_arena.material = _arena_mat
	add_child(_arena)
	move_child(_arena, 0)

	# Dims the backdrop on the win screen (sits above the arena, below the wizards).
	_dim = ColorRect.new()
	_dim.size = Vector2(1920, 1080)
	_dim.color = Color(0.02, 0.0, 0.06, 0.0)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	move_child(_dim, 1)
	# Full-screen flash on the final blow (above everything).
	_flash = ColorRect.new()
	_flash.size = Vector2(1920, 1080)
	_flash.color = Color(1, 1, 1, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)

	_add_ambient_particles()
	_debug = DebugOverlay.new()
	_debug.size = Vector2(1920, 1080)
	add_child(_debug)

	for w in [fire, water]:
		w.mirror_x = MIRROR
		w.gestures.bolt_cast.connect(_on_bolt.bind(w))
		w.gestures.wave_cast.connect(_on_wave.bind(w))
		w.died.connect(_on_died.bind(w))
	Tracking.frame_received.connect(_on_tracking_frame)
	hud.setup(fire, water)

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshots="):
			_shot_dir = arg.get_slice("=", 1)
		elif arg.begins_with("--shot-count="):
			_shot_count = maxi(1, int(arg.get_slice("=", 1)))
	if _shot_dir != "":
		_run_screenshots()


func _run_screenshots() -> void:
	DirAccess.make_dir_recursive_absolute(_shot_dir)
	for i in _shot_count:
		await get_tree().create_timer(SHOT_INTERVAL).timeout
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := _shot_dir.path_join("shot_%02d.png" % i)
		var err := img.save_png(path)
		print("screenshot %s (%s)" % [path, error_string(err)])
	get_tree().quit()


func _add_ambient_particles() -> void:
	var embers := CPUParticles2D.new()
	embers.amount = 90
	embers.lifetime = 6.0
	embers.preprocess = 6.0
	embers.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	embers.emission_rect_extents = Vector2(480, 80)
	embers.position = Vector2(480, 1000)
	embers.direction = Vector2(0.15, -1)
	embers.spread = 25.0
	embers.gravity = Vector2(0, -25)
	embers.initial_velocity_min = 25.0
	embers.initial_velocity_max = 90.0
	embers.scale_amount_min = 0.15
	embers.scale_amount_max = 0.4
	embers.texture = WizardFX.soft_particle_texture()
	embers.color = Color(1.0, 0.55, 0.15, 0.8)
	var er := Gradient.new()
	er.set_color(0, Color(1.0, 0.8, 0.3, 0.0))
	er.add_point(0.15, Color(1.0, 0.6, 0.15, 0.9))
	er.set_color(er.get_point_count() - 1, Color(0.8, 0.2, 0.05, 0.0))
	embers.color_ramp = er
	add_child(embers)
	move_child(embers, 2)

	var mist := CPUParticles2D.new()
	mist.amount = 70
	mist.lifetime = 7.0
	mist.preprocess = 7.0
	mist.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	mist.emission_rect_extents = Vector2(480, 60)
	mist.position = Vector2(1440, 120)
	mist.direction = Vector2(-0.1, 1)
	mist.spread = 20.0
	mist.gravity = Vector2(0, 30)
	mist.initial_velocity_min = 20.0
	mist.initial_velocity_max = 70.0
	mist.scale_amount_min = 0.15
	mist.scale_amount_max = 0.35
	mist.texture = WizardFX.soft_particle_texture()
	var mr := Gradient.new()
	mr.set_color(0, Color(0.7, 0.95, 1.0, 0.0))
	mr.add_point(0.2, Color(0.5, 0.85, 1.0, 0.8))
	mr.set_color(mr.get_point_count() - 1, Color(0.3, 0.6, 1.0, 0.0))
	mist.color_ramp = mr
	add_child(mist)
	move_child(mist, 3)


## Brief freeze, then slow motion, then back to normal. Real-time durations.
func _hit_stop(freeze_s: float, slow_scale: float, slow_s: float) -> void:
	Engine.time_scale = 0.02
	await get_tree().create_timer(freeze_s, true, false, true).timeout
	Engine.time_scale = slow_scale
	await get_tree().create_timer(slow_s, true, false, true).timeout
	Engine.time_scale = 1.0


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# -- Body assignment ---------------------------------------------------------

func _on_tracking_frame(bodies: Array) -> void:
	var now := _now()
	var unassigned: Array = bodies.duplicate()

	# Keep bodies that are already attached to a wizard.
	for w in [fire, water]:
		if w.body_id == "":
			continue
		for raw_body in unassigned:
			var b: BodyData = raw_body
			if b.id == w.body_id:
				w.set_body(b, now)
				unassigned.erase(b)
				break

	# Hand out new bodies to free wizards, nearest lane first.
	for raw_body in unassigned:
		var b: BodyData = raw_body
		var est_x := 960.0 + b.joint("SpineBase").x * Wizard.PIXELS_PER_METER * (-1.0 if MIRROR else 1.0)
		var best: Wizard = null
		var best_dist := INF
		for w in [fire, water]:
			if w.body != null and now - w.body_seen_at < 0.5:
				continue
			var d := absf(w.position.x - est_x)
			if d < best_dist:
				best_dist = d
				best = w
		if best != null:
			best.set_body(b, now)
			print("%s tracked as body %s" % [best.display_name(), b.id])


# -- Round flow --------------------------------------------------------------

func _process(delta: float) -> void:
	var now := _now()
	fire.check_timeout(now)
	water.check_timeout(now)

	match state:
		State.WAITING:
			if fire.is_tracked() and water.is_tracked():
				_start_countdown()
		State.COUNTDOWN:
			countdown -= delta
			if countdown <= 0.0:
				state = State.FIGHT
				print("round: fight")
		State.FIGHT:
			_update_spells(delta)
		State.OVER:
			_update_spells(delta)
			if fire.gestures.shield_active and water.gestures.shield_active:
				restart_hold += delta
				if restart_hold >= RESTART_HOLD_SEC:
					_start_countdown()
			else:
				restart_hold = 0.0
	_update_hud()
	_fire_energy = maxf(0.0, _fire_energy - delta * 2.0)
	_water_energy = maxf(0.0, _water_energy - delta * 2.0)
	_arena_mat.set_shader_parameter("fire_energy", _fire_energy)
	_arena_mat.set_shader_parameter("water_energy", _water_energy)
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 40.0)
		position = Vector2(randf_range(-_shake, _shake), randf_range(-_shake, _shake))
	else:
		position = Vector2.ZERO
	queue_redraw()


func _start_countdown() -> void:
	for s in _spells:
		s.queue_free()
	_spells.clear()
	fire.reset_round()
	water.reset_round()
	winner = null
	restart_hold = 0.0
	Engine.time_scale = 1.0
	if _dim != null:
		create_tween().tween_property(_dim, "color:a", 0.0, 0.4)
	countdown = COUNTDOWN_SEC
	state = State.COUNTDOWN
	print("round: countdown")


func _on_died(w: Wizard) -> void:
	if state != State.FIGHT:
		return
	winner = water if w == fire else fire
	winner.outcome = "win"
	w.outcome = "lose"
	state = State.OVER
	_flash.color.a = 0.85
	var tw := create_tween()
	tw.tween_property(_flash, "color:a", 0.0, 0.5).set_ease(Tween.EASE_OUT)
	var dim_tw := create_tween()
	dim_tw.tween_property(_dim, "color:a", 0.45, 1.2)
	_hit_stop(0.12, 0.25, 0.9)
	print("round: over, %s wins" % winner.display_name())


func _update_hud() -> void:
	match state:
		State.WAITING:
			hud.center_text = "WIZARD WARS"
			var missing: Array[String] = []
			if not fire.is_tracked():
				missing.append("fire")
			if not water.is_tracked():
				missing.append("water")
			if not Tracking.is_background_ready():
				hud.sub_text = "Learning the empty room, stay out of view for a moment"
			else:
				hud.sub_text = "Step in front of the camera  (waiting for: %s)" % ", ".join(missing)
			hud.hint_text = "PUNCH forward = bolt    SWEEP sideways = wave    BOTH HANDS UP = shield"
		State.COUNTDOWN:
			hud.center_text = "FIGHT!" if countdown < 0.6 else str(ceili(countdown - 0.5))
			hud.sub_text = ""
			hud.hint_text = ""
		State.FIGHT:
			hud.center_text = ""
			hud.sub_text = ""
			hud.hint_text = ""
		State.OVER:
			hud.center_text = "%s WINS" % winner.display_name() if winner != null else "DRAW"
			hud.sub_text = "Both raise your hands to fight again"
			hud.hint_text = ""
	hud.status_text = Tracking.source_description()


# -- Casting -----------------------------------------------------------------

func _on_bolt(hand: String, w: Wizard) -> void:
	_cast(Spell.Kind.BOLT, w, w.hand_global_position(hand))


func _on_wave(hand: String, _direction: int, w: Wizard) -> void:
	_cast(Spell.Kind.WAVE, w, w.hand_global_position(hand))


func _cast(kind: Spell.Kind, w: Wizard, origin: Vector2) -> void:
	if state != State.FIGHT:
		return
	var cost := Spell.cost_of(kind)
	if not w.can_cast(cost):
		return
	w.spend_mana(cost)
	origin.y = clampf(origin.y, 200.0, 900.0)
	origin.x += w.facing * 60.0
	var s := Spell.make(kind, w.element, w, origin, w.facing)
	spells_root.add_child(s)
	_spells.append(s)
	FXRing.spawn(spells_root, origin, w.glow_color(), 140.0 if kind == Spell.Kind.BOLT else 260.0, 0.45)
	if w == fire:
		_fire_energy = 1.0
	else:
		_water_energy = 1.0
	print("%s casts %s (mana left %d)" % [w.display_name(), "bolt" if kind == Spell.Kind.BOLT else "wave", w.mana])


func _opponent_of(w: Wizard) -> Wizard:
	return water if w == fire else fire


# -- Spell simulation --------------------------------------------------------

func _update_spells(_delta: float) -> void:
	# Spell versus spell.
	for i in _spells.size():
		var a := _spells[i]
		if not a.alive:
			continue
		for j in range(i + 1, _spells.size()):
			var b := _spells[j]
			if not b.alive or a.caster == b.caster:
				continue
			var dx := absf(a.position.x - b.position.x)
			var dy := absf(a.position.y - b.position.y)
			if dx <= a.radius + b.radius and dy <= a.half_height + b.half_height:
				_resolve_clash(a, b)

	# Spell reaching the opposing wizard, or leaving the screen.
	for s in _spells:
		if not s.alive:
			continue
		var target := _opponent_of(s.caster)
		var reached := (s.direction > 0 and s.position.x >= target.position.x - HIT_MARGIN) \
			or (s.direction < 0 and s.position.x <= target.position.x + HIT_MARGIN)
		if reached:
			_resolve_hit(s, target)
		elif s.position.x < -200.0 or s.position.x > 2120.0:
			s.extinguish()

	_spells = _spells.filter(func(s: Spell) -> bool: return is_instance_valid(s) and s.alive)


func _resolve_clash(a: Spell, b: Spell) -> void:
	var mid := (a.position + b.position) * 0.5
	if a.kind == Spell.Kind.BOLT and b.kind == Spell.Kind.BOLT:
		var water_bolt := a if a.element == "water" else b
		var fire_bolt := b if water_bolt == a else a
		if water_bolt.element == fire_bolt.element:
			a.extinguish()
			b.extinguish()
		else:
			fire_bolt.extinguish()
			water_bolt.power = minf(water_bolt.power, CLASH_WATER_BOLT_SURVIVES_AT)
	elif a.kind == Spell.Kind.WAVE and b.kind == Spell.Kind.WAVE:
		a.extinguish()
		b.extinguish()
	else:
		var wave := a if a.kind == Spell.Kind.WAVE else b
		var bolt := b if wave == a else a
		bolt.extinguish()
		wave.power -= CLASH_WAVE_POWER_LOSS
		if wave.power <= 0.0:
			wave.extinguish()
	_burst(mid, Color(1.0, 1.0, 1.0), 40)
	FXRing.spawn(spells_root, mid, Color(0.9, 0.85, 1.0), 180.0, 0.4)
	fire.fx.burst_shards(mid, Color(0.95, 0.9, 1.0), 300.0)
	FXBurst.spawn(spells_root, mid, a.element, 260.0, Color(1, 1, 1, 0.8))
	FXBurst.spawn(spells_root, mid, b.element, 260.0, Color(1, 1, 1, 0.8))
	_shake = maxf(_shake, 4.0)


func _resolve_hit(s: Spell, target: Wizard) -> void:
	if target.shield_up:
		var drain := SHIELD_DRAIN_WAVE
		if s.kind == Spell.Kind.BOLT:
			drain = SHIELD_DRAIN_FIRE_VS_WATER if s.element == "fire" else SHIELD_DRAIN_WATER_VS_FIRE
		target.drain_mana(drain * s.power)
		_burst(s.position, target.color(), 30)
		FXRing.spawn(spells_root, s.position, target.glow_color(), 220.0, 0.5)
		target.fx.burst_shards(s.position, target.glow_color(), 360.0)
		FXBurst.spawn(spells_root, s.position, s.element, 300.0, Color(1, 1, 1, 0.7))
		_shake = maxf(_shake, 3.0)
	else:
		target.take_damage(s.damage * s.power)
		_burst(s.position, s.color(), 60)
		FXRing.spawn(spells_root, s.position, s.bright_color(), 300.0, 0.55)
		target.fx.burst_shards(s.position, s.bright_color(), 420.0)
		FXBurst.spawn(spells_root, s.position, s.element, 520.0 if s.kind == Spell.Kind.WAVE else 400.0)
		if target.hp > 0.0:
			_hit_stop(0.05, 0.6, 0.12)
		FXRing.spawn(spells_root, Vector2(target.position.x, Wizard.GROUND_Y + 6.0), s.color(), 260.0, 0.6, 0.28)
		_shake = maxf(_shake, 6.0 if s.kind == Spell.Kind.BOLT else 12.0)
		print("%s hit by %s %s for %d (hp %d)" % [target.display_name(), s.element, "bolt" if s.kind == Spell.Kind.BOLT else "wave", s.damage * s.power, target.hp])
	s.extinguish()


func _burst(at: Vector2, c: Color, amount: int) -> void:
	var p := CPUParticles2D.new()
	p.position = at
	p.amount = amount
	p.one_shot = true
	p.explosiveness = 1.0
	p.lifetime = 0.6
	p.spread = 180.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 150.0
	p.initial_velocity_max = 420.0
	p.scale_amount_min = 3.0
	p.scale_amount_max = 8.0
	p.color = c
	p.texture = WizardFX.soft_particle_texture()
	p.scale_amount_min = 0.3
	p.scale_amount_max = 0.8
	spells_root.add_child(p)
	p.emitting = true
	get_tree().create_timer(1.0).timeout.connect(p.queue_free)


# -- Debug keyboard ----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_Q: _cast(Spell.Kind.BOLT, fire, fire.hand_global_position("right"))
		KEY_W: _cast(Spell.Kind.WAVE, fire, fire.hand_global_position("right"))
		KEY_E: fire.set_shield(not fire.shield_up)
		KEY_I: _cast(Spell.Kind.BOLT, water, water.hand_global_position("right"))
		KEY_O: _cast(Spell.Kind.WAVE, water, water.hand_global_position("right"))
		KEY_P: water.set_shield(not water.shield_up)
		KEY_ENTER, KEY_KP_ENTER:
			if state == State.WAITING or state == State.OVER:
				_start_countdown()
		KEY_R:
			_start_countdown()
		KEY_B:
			Tracking.learn_background()
		KEY_D:
			_debug.enabled = not _debug.enabled
		KEY_ESCAPE:
			get_tree().quit()


# -- Background is the arena shader on a full-screen ColorRect (see _ready). --
