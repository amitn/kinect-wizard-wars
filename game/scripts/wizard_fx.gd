class_name WizardFX
extends Node2D
## The wizard's look: an elemental aura shaped by the body mask, the body painted
## as a hooded robe, glowing hands with particles, eyes, and a ground glow.
## Works from a depth-camera silhouette or, when only joints exist, from a robe
## drawn into a small SubViewport that serves as the mask.

const AURA_SHADER := preload("res://shaders/aura.gdshader")
const ROBE_SHADER := preload("res://shaders/robe.gdshader")
const MASK_VP_SIZE := Vector2i(192, 480)

static var _noise_tex: NoiseTexture2D = null
static var trace_poses := false   # print pose changes (set by --tracklog)
static var _soft_tex: GradientTexture2D = null

var element := "fire"
var mirror_x := true

var _aura: Sprite2D
var _body: Sprite2D
var _reflect: Sprite2D
var _face: Node2D
var _hand_l: CPUParticles2D
var _hand_r: CPUParticles2D
var _orb_sprites: Array = []      # two additive Sprite2D showing the orb art in the hands
var _orb_tex: Texture2D = null
var _shield_since := -10.0
var _mask_vp: SubViewport
var _mask_painter: Node2D
var _white_tex: ImageTexture
var _robe_material: ShaderMaterial
var _sil_tex: ImageTexture = null

var _body_rect := Rect2()      # where the body mask lands in local space
var _pose_tex: Dictionary = {}     # pose -> Texture2D (single still), when art exists
var _pose_frames: Dictionary = {}  # pose -> Array[Texture2D] animation frames, when art exists
var _anim_pose := ""
var _anim_started := 0.0
const ANIM_FPS := {"idle": 5.0, "cast": 12.0, "shield": 12.0, "hit": 10.0, "collapse": 8.0, "victory": 6.0}
const ANIM_LOOPS := {"idle": true, "victory": true}
var _circle_tex: Texture2D = null
var _barrier_tex: Texture2D = null
var _shards_tex: Texture2D = null
var _pose := "idle"
var depth_scale := 1.0            # 1 at the ideal distance; set by Wizard from the player's depth
var _hands_active: Array = [true, true]
var _outcome := ""
var _outcome_since := 0.0
var _head_pos := Vector2.ZERO
var _hand_pos := [Vector2.ZERO, Vector2.ZERO]
var _feet_y := 940.0
var _shield_up := false
var _facing := 1
var _visible_body := false
var _skeleton_joints: Dictionary = {}   # joint name -> local Vector2, for the mask painter


## A soft radial dot for every particle system, instead of Godot's hard square point.
static func soft_particle_texture() -> GradientTexture2D:
	if _soft_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.add_point(0.35, Color(1, 1, 1, 0.75))
		g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0))
		_soft_tex = GradientTexture2D.new()
		_soft_tex.gradient = g
		_soft_tex.fill = GradientTexture2D.FILL_RADIAL
		_soft_tex.fill_from = Vector2(0.5, 0.5)
		_soft_tex.fill_to = Vector2(0.5, 0.0)
		_soft_tex.width = 32
		_soft_tex.height = 32
	return _soft_tex


static func noise_texture() -> NoiseTexture2D:
	if _noise_tex == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 0.02
		n.fractal_octaves = 4
		_noise_tex = NoiseTexture2D.new()
		_noise_tex.width = 256
		_noise_tex.height = 256
		_noise_tex.seamless = true
		_noise_tex.noise = n
	return _noise_tex


func _ready() -> void:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_white_tex = ImageTexture.create_from_image(img)

	_aura = Sprite2D.new()
	_aura.centered = false
	_aura.texture = _white_tex
	var am := ShaderMaterial.new()
	am.shader = AURA_SHADER
	am.set_shader_parameter("noise_tex", noise_texture())
	_aura.material = am
	add_child(_aura)

	_mask_vp = SubViewport.new()
	_mask_vp.size = MASK_VP_SIZE
	_mask_vp.transparent_bg = true
	_mask_vp.disable_3d = true
	_mask_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_mask_painter = Node2D.new()
	_mask_painter.draw.connect(_paint_skeleton_mask)
	_mask_vp.add_child(_mask_painter)
	add_child(_mask_vp)

	_body = Sprite2D.new()
	_body.centered = false
	var rm := ShaderMaterial.new()
	rm.shader = ROBE_SHADER
	rm.set_shader_parameter("noise_tex", noise_texture())
	_robe_material = rm
	_body.material = rm
	add_child(_body)

	_reflect = Sprite2D.new()
	_reflect.centered = false
	_reflect.flip_v = true
	_reflect.material = rm
	_reflect.modulate = Color(1, 1, 1, 0.22)
	add_child(_reflect)
	move_child(_reflect, 0)

	_hand_l = _make_hand_particles()
	_hand_r = _make_hand_particles()
	add_child(_hand_l)
	add_child(_hand_r)
	for k in 2:
		var sp := Sprite2D.new()
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		sp.material = mat
		sp.visible = false
		add_child(sp)
		_orb_sprites.append(sp)

	_face = Node2D.new()
	_face.draw.connect(_draw_face)
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_face.material = add_mat
	material = add_mat
	add_child(_face)

	_apply_palette()
	_load_art()


## Generated art lives in res://art. Anything missing falls back to the procedural look.
func _load_art() -> void:
	for pose in ["idle", "cast", "shield", "hit", "collapse", "prone", "victory"]:
		var path := "res://art/%s_%s.png" % [element, pose]
		if ResourceLoader.exists(path):
			_pose_tex[pose] = load(path)
		var frames: Array = []
		for i in 12:
			var fpath := "res://art/%s_%s_%d.png" % [element, pose, i]
			if not ResourceLoader.exists(fpath):
				break
			frames.append(load(fpath))
		if frames.size() > 1:
			_pose_frames[pose] = frames
	if ResourceLoader.exists("res://art/spell_circle.png"):
		_circle_tex = load("res://art/spell_circle.png")
	var barrier := "res://art/%s_barrier.png" % element
	if ResourceLoader.exists(barrier):
		_barrier_tex = load(barrier)
	if ResourceLoader.exists("res://art/shards.png"):
		_shards_tex = load("res://art/shards.png")
	var orb := "res://art/%s_orb.png" % element
	if ResourceLoader.exists(orb):
		_orb_tex = load(orb)
		for sp in _orb_sprites:
			sp.texture = _orb_tex
			# Only the ball, not the trailing flames on the left of the orb art.
			sp.region_enabled = true
			var tw := _orb_tex.get_width()
			var th := _orb_tex.get_height()
			sp.region_rect = Rect2(tw * 0.52, th * 0.2, tw * 0.46, th * 0.6)


func has_pose_art() -> bool:
	return _pose_tex.has("idle") or _pose_frames.has("idle")


## Length in seconds of a one-shot animation, 0 when the pose is a still.
func _anim_length(pose: String) -> float:
	if not _pose_frames.has(pose):
		return 0.0
	return (_pose_frames[pose] as Array).size() / float(ANIM_FPS.get(pose, 8.0))


## Texture for the pose right now: the animation frame if frames exist, else the still.
## One-shot animations hold their last frame once finished.
func _frame_for(pose: String, now: float) -> Texture2D:
	if pose != _anim_pose:
		if trace_poses:
			print("pose: %s -> %s (%s)" % [_anim_pose, pose, element])
		_anim_pose = pose
		_anim_started = now
	if _pose_frames.has(pose):
		var frames: Array = _pose_frames[pose]
		var idx := int((now - _anim_started) * float(ANIM_FPS.get(pose, 8.0)))
		if ANIM_LOOPS.get(pose, false):
			idx = idx % frames.size()
		else:
			idx = mini(idx, frames.size() - 1)
		return frames[idx]
	return _pose_tex.get(pose, _pose_tex.get("idle"))


func _make_hand_particles() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = 60
	p.lifetime = 0.6
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 26.0
	p.direction = Vector2(0, -1)
	p.spread = 40.0
	p.initial_velocity_min = 40.0
	p.initial_velocity_max = 120.0
	p.scale_amount_min = 0.35
	p.scale_amount_max = 0.9
	p.texture = soft_particle_texture()
	p.local_coords = false
	return p


func _apply_palette() -> void:
	var am := _aura.material as ShaderMaterial
	var rm := _robe_material
	var ramp := Gradient.new()
	if element == "fire":
		am.set_shader_parameter("color_core", Color(1.0, 0.95, 0.55))
		am.set_shader_parameter("color_mid", Color(1.0, 0.45, 0.08))
		am.set_shader_parameter("color_edge", Color(0.75, 0.08, 0.02))
		am.set_shader_parameter("rise", 1.0)
		am.set_shader_parameter("swirl", 0.0)
		am.set_shader_parameter("speed", 0.9)
		# Black coat cracked with lava light, orange rune trim.
		rm.set_shader_parameter("robe", Color(0.16, 0.08, 0.08))
		rm.set_shader_parameter("robe_dark", Color(0.06, 0.03, 0.04))
		rm.set_shader_parameter("cape", Color(0.30, 0.06, 0.05))
		rm.set_shader_parameter("hood", Color(0.10, 0.04, 0.04))
		rm.set_shader_parameter("trim", Color(1.0, 0.55, 0.15))
		rm.set_shader_parameter("rim", Color(1.0, 0.45, 0.12))
		rm.set_shader_parameter("veins", Color(1.0, 0.40, 0.08))
		rm.set_shader_parameter("vein_strength", 1.0)
		ramp.set_color(0, Color(1.0, 0.9, 0.4))
		ramp.set_color(1, Color(1.0, 0.3, 0.05, 0.0))
		for p in [_hand_l, _hand_r]:
			p.gravity = Vector2(0, -160)
			p.color_ramp = ramp
	else:
		am.set_shader_parameter("color_core", Color(0.55, 0.9, 1.0))
		am.set_shader_parameter("color_mid", Color(0.15, 0.5, 1.0))
		am.set_shader_parameter("color_edge", Color(0.03, 0.1, 0.5))
		am.set_shader_parameter("rise", 0.8)
		am.set_shader_parameter("swirl", 1.0)
		am.set_shader_parameter("speed", 0.7)
		# Deep navy coat with frost-blue veins and pale trim.
		rm.set_shader_parameter("robe", Color(0.06, 0.12, 0.30))
		rm.set_shader_parameter("robe_dark", Color(0.02, 0.05, 0.16))
		rm.set_shader_parameter("cape", Color(0.10, 0.28, 0.55))
		rm.set_shader_parameter("hood", Color(0.04, 0.09, 0.24))
		rm.set_shader_parameter("trim", Color(0.55, 0.85, 1.0))
		rm.set_shader_parameter("rim", Color(0.45, 0.80, 1.0))
		rm.set_shader_parameter("veins", Color(0.35, 0.75, 1.0))
		rm.set_shader_parameter("vein_strength", 0.9)
		ramp.set_color(0, Color(0.8, 0.95, 1.0))
		ramp.set_color(1, Color(0.2, 0.5, 1.0, 0.0))
		for p in [_hand_l, _hand_r]:
			p.gravity = Vector2(0, 220)
			p.color_ramp = ramp


func glow_color() -> Color:
	return Color(1.0, 0.85, 0.3) if element == "fire" else Color(0.7, 0.95, 1.0)


func set_element(new_element: String) -> void:
	element = new_element
	if _aura != null:
		_apply_palette()


## Called by the wizard every frame with everything the look depends on.
## `silhouette` may be null; then `joints` (name -> local Vector2) drives a drawn robe.
func update_look(silhouette: Image, sil_center: Vector2i, sil_rect: Rect2, joints: Dictionary,
		head: Vector2, hand_left: Vector2, hand_right: Vector2, feet_y: float,
		shield_up: bool, facing: int, hit_flash: float, cast_flash: float,
		hands_active: Array = [true, true], outcome: String = "") -> void:
	_visible_body = true
	_hands_active = hands_active
	if outcome != _outcome:
		_outcome = outcome
		_outcome_since = Time.get_ticks_msec() / 1000.0
	_head_pos = head
	_hand_pos = [hand_left, hand_right]
	_feet_y = feet_y
	_shield_up = shield_up
	_facing = facing
	_skeleton_joints = joints

	if has_pose_art():
		# Pose sprite: bottom on the feet, centred on the body, sized to the tracked height.
		var want := "idle"
		var now := Time.get_ticks_msec() / 1000.0
		var since := now - _outcome_since
		var collapse_len := maxf(0.7, _anim_length("collapse"))
		if _outcome == "lose":
			want = "collapse" if (since < collapse_len or _pose_frames.has("collapse")) else "prone"
		elif _outcome == "win":
			want = "victory"
		elif hit_flash > 0.0 or (_anim_pose == "hit" and now - _anim_started < _anim_length("hit")):
			want = "hit"
		elif shield_up:
			want = "shield"
		elif cast_flash > 0.0 or (_anim_pose == "cast" and now - _anim_started < _anim_length("cast")):
			want = "cast"
		if not (_pose_tex.has(want) or _pose_frames.has(want)):
			want = "hit" if want == "collapse" and (_pose_tex.has("hit") or _pose_frames.has("hit")) else "idle"
		_pose = want
		var tex: Texture2D = _frame_for(_pose, now)
		var center_x := head.x
		if joints.has("SpineBase"):
			center_x = (joints["SpineBase"] as Vector2).x
		# Each pose PNG is cropped tight, so scale it by how tall that pose is
		# relative to the standing figure, keeping the character one size.
		const POSE_HEIGHT := {"idle": 1.0, "cast": 0.97, "shield": 1.22, "hit": 0.9,
			"collapse": 0.55, "prone": 0.24, "victory": 1.12}
		var target_h := ((feet_y - head.y) * 1.08 + 20.0) * depth_scale
		# Animation strips are cut to one uniform height (the standing figure, or the
		# raised arms for the shield), so they use a flatter factor than the stills.
		var factor := float(POSE_HEIGHT.get(_pose, 1.0))
		if _pose_frames.has(_pose):
			factor = 1.22 if _pose == "shield" else 1.0
		var scale := target_h * factor / tex.get_height()
		var size := Vector2(tex.get_size()) * scale
		_body.texture = tex
		_body.flip_h = _facing < 0
		_body.material = null
		_body_rect = Rect2(Vector2(center_x - size.x * 0.5, feet_y - size.y), size)
		_mask_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif silhouette != null:
		_body.material = _robe_material
		if _sil_tex == null or _sil_tex.get_size() != Vector2(silhouette.get_size()):
			_sil_tex = ImageTexture.create_from_image(silhouette)
		else:
			_sil_tex.update(silhouette)
		_body.texture = _sil_tex
		_body.flip_h = mirror_x
		_body_rect = sil_rect
		_mask_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		_body.material = _robe_material
		_mask_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_body.texture = _mask_vp.get_texture()
		_body.flip_h = false
		_body_rect = _skeleton_bounds()
		_mask_painter.queue_redraw()

	_body.position = _body_rect.position
	_body.scale = _body_rect.size / Vector2(_body.texture.get_size()) if _body.texture != null else Vector2.ONE
	var flash := Color.WHITE.lerp(Color(3.0, 3.0, 3.0), clampf(hit_flash * 2.5, 0.0, 1.0))
	_body.modulate = flash
	# Mirror image in the floor, squashed and faint.
	_reflect.texture = _body.texture
	_reflect.material = _body.material
	_reflect.flip_h = _body.flip_h
	_reflect.position = Vector2(_body_rect.position.x, feet_y + 8.0)
	_reflect.scale = Vector2(_body.scale.x, _body.scale.y * 0.55)
	_reflect.visible = true

	# Aura quad: body rect grown sideways and in the rise direction.
	var grow_x := _body_rect.size.x * 0.9 + 60.0
	var grow_up := _body_rect.size.y * 0.55 if element == "fire" else _body_rect.size.y * 0.15
	var grow_down := _body_rect.size.y * 0.15 if element == "fire" else _body_rect.size.y * 0.45
	var aura_rect := Rect2(_body_rect.position - Vector2(grow_x, grow_up), _body_rect.size + Vector2(grow_x * 2.0, grow_up + grow_down))
	_aura.position = aura_rect.position
	_aura.scale = aura_rect.size / Vector2(_white_tex.get_size())
	var am := _aura.material as ShaderMaterial
	am.set_shader_parameter("mask_tex", _body.texture)
	am.set_shader_parameter("flip_x", 1.0 if _body.flip_h else 0.0)
	am.set_shader_parameter("mask_rect_min", (_body_rect.position - aura_rect.position) / aura_rect.size)
	am.set_shader_parameter("mask_rect_size", _body_rect.size / aura_rect.size)
	var base_intensity := 0.55 if has_pose_art() else 0.85
	am.set_shader_parameter("intensity", base_intensity + 0.6 * clampf(cast_flash * 4.0, 0.0, 1.0) + (0.3 if shield_up else 0.0))
	am.set_shader_parameter("spread", 0.22 if has_pose_art() else 0.35)
	_aura.visible = true
	_body.visible = true

	_hand_l.position = hand_left
	_hand_r.position = hand_right
	_hand_l.emitting = bool(_hands_active[0])
	_hand_r.emitting = bool(_hands_active[1])
	if shield_up and _shield_since < 0.0:
		_shield_since = Time.get_ticks_msec() / 1000.0
		_on_shield_raised()
	elif not shield_up:
		_shield_since = -10.0
	if _orb_tex != null:
		var tnow := Time.get_ticks_msec() / 1000.0
		for k in 2:
			var sp: Sprite2D = _orb_sprites[k]
			sp.visible = bool(_hands_active[k])
			if not sp.visible:
				continue
			sp.position = _hand_pos[k]
			var pulse := 1.0 + 0.08 * sin(tnow * 11.0 + k * 2.0) + (0.25 if shield_up else 0.0)
			var target := 150.0 * pulse
			sp.scale = Vector2.ONE * (target / sp.region_rect.size.y)
			sp.rotation = tnow * (1.2 if k == 0 else -1.0)
			sp.modulate = Color(1, 1, 1, 0.95)
	_face.queue_redraw()
	queue_redraw()


## Crystal shard burst at a point (blocked hits, clashes). Falls back to nothing without art.
func burst_shards(at_global: Vector2, tint: Color, size: float = 320.0) -> void:
	if _shards_tex == null:
		return
	var sp := Sprite2D.new()
	sp.texture = _shards_tex
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	sp.material = mat
	sp.global_position = at_global
	sp.rotation = randf() * TAU
	sp.modulate = tint
	var s0 := size * 0.4 / _shards_tex.get_width()
	sp.scale = Vector2.ONE * s0
	get_tree().root.add_child(sp)
	var tw := sp.create_tween().set_parallel(true)
	tw.tween_property(sp, "scale", Vector2.ONE * (size / _shards_tex.get_width()), 0.45).set_ease(Tween.EASE_OUT)
	tw.tween_property(sp, "modulate:a", 0.0, 0.45).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(sp.queue_free)


## The barrier forms: a burst and ring where it appears.
func _on_shield_raised() -> void:
	var h := _body_rect.size.y * 1.05
	var w := h * (_barrier_tex.get_width() / float(_barrier_tex.get_height())) if _barrier_tex != null else 200.0
	var bx := _body_rect.get_center().x + _facing * (_body_rect.size.x * 0.5 + w * 0.2)
	var at := to_global(Vector2(bx, _feet_y - h * 0.5))
	var root := get_tree().root
	FXBurst.spawn(root, at, element, 520.0, Color(1, 1, 1, 0.9))
	FXRing.spawn(root, at, glow_color(), 260.0, 0.45)


func hide_body() -> void:
	_visible_body = false
	for sp in _orb_sprites:
		sp.visible = false
	_aura.visible = false
	_body.visible = false
	_reflect.visible = false
	_hand_l.emitting = false
	_hand_r.emitting = false
	_face.queue_redraw()
	queue_redraw()


func _skeleton_bounds() -> Rect2:
	if _skeleton_joints.is_empty():
		return Rect2(-120, _feet_y - 560, 240, 560)
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in _skeleton_joints.values():
		mn = mn.min(p)
		mx = mx.max(p)
	mn -= Vector2(70, 60)
	mx += Vector2(70, 20)
	return Rect2(mn, mx - mn)


## Draws a robed, pointy-hatted figure in white into the SubViewport, in mask coordinates.
func _paint_skeleton_mask() -> void:
	if _skeleton_joints.is_empty() or _body_rect.size.x <= 0.0:
		return
	var sc := Vector2(MASK_VP_SIZE) / _body_rect.size
	var c := _mask_painter
	var J := func(name: String) -> Vector2:
		return (_skeleton_joints.get(name, _body_rect.get_center()) - _body_rect.position) * sc
	var head: Vector2 = J.call("Head")
	var neck: Vector2 = J.call("SpineShoulder")
	var hips: Vector2 = J.call("SpineBase")
	var m := 320.0 * sc.y   # pixels per meter in mask space
	var shl: Vector2 = J.call("ShoulderLeft") if _skeleton_joints.has("ShoulderLeft") else neck + Vector2(-0.19 * m, 0.02 * m)
	var shr: Vector2 = J.call("ShoulderRight") if _skeleton_joints.has("ShoulderRight") else neck + Vector2(0.19 * m, 0.02 * m)
	var hl: Vector2 = J.call("HandLeft")
	var hr: Vector2 = J.call("HandRight")
	var fl: Vector2 = J.call("FootLeft")
	var fr: Vector2 = J.call("FootRight")
	var hem_y: float = maxf(fl.y, fr.y) + 0.02 * m
	var w := Color.WHITE
	var head_r: float = 0.11 * m
	var shoulder_w: float = shr.x - shl.x
	# Neck and hood.
	c.draw_line(head, neck, w, head_r * 0.9, true)
	c.draw_circle(head, head_r * 1.05, w)
	# Tall floppy wizard hat: narrow brim, a bent cone leaning toward the opponent.
	var brim_y: float = head.y - head_r * 0.6
	c.draw_set_transform(Vector2(head.x, brim_y), 0.0, Vector2(1.0, 0.28))
	c.draw_circle(Vector2.ZERO, head_r * 1.9, w)
	c.draw_set_transform(Vector2.ZERO)
	var tip := Vector2(head.x + head_r * 1.6 * _facing, brim_y - head_r * 3.6)
	var bend := Vector2(head.x + head_r * 0.3 * _facing, brim_y - head_r * 2.2)
	c.draw_colored_polygon(PackedVector2Array([
		Vector2(head.x - head_r * 1.05, brim_y), Vector2(head.x + head_r * 1.05, brim_y),
		bend + Vector2(head_r * 0.45, 0.0), tip, bend - Vector2(head_r * 0.45, 0.0)]), w)
	# Cape: from just above the shoulders flaring to the hips.
	var cape_flare: float = shoulder_w * 0.18
	c.draw_colored_polygon(PackedVector2Array([
		shl + Vector2(-head_r * 0.15, -head_r * 0.4), shr + Vector2(head_r * 0.15, -head_r * 0.4),
		Vector2(shr.x + cape_flare, hips.y + 0.1 * m), Vector2(shl.x - cape_flare, hips.y + 0.1 * m)]), w)
	# Robe: shoulders in to a waist, then a flared hem.
	var flare: float = shoulder_w * 0.3
	c.draw_colored_polygon(PackedVector2Array([
		shl + Vector2(shoulder_w * 0.05, 0.0), shr - Vector2(shoulder_w * 0.05, 0.0),
		Vector2(shr.x - shoulder_w * 0.15, hips.y), Vector2(shr.x + flare, hem_y),
		Vector2(shl.x - flare, hem_y), Vector2(shl.x + shoulder_w * 0.15, hips.y)]), w)
	# Sleeves widening toward the hands, and the hands.
	for pair in [[shl, hl], [shr, hr]]:
		var a: Vector2 = pair[0]
		var b: Vector2 = pair[1]
		c.draw_line(a, b, w, 0.09 * m, true)
		var mid: Vector2 = a.lerp(b, 0.7)
		c.draw_line(mid, b, w, 0.13 * m, true)
		c.draw_circle(b, 0.055 * m, w)
	for f in [fl, fr]:
		c.draw_circle(f, 0.045 * m, w)


func _draw() -> void:
	if not _visible_body:
		return
	# Magic circle on the floor: glowing rings and a slowly turning pentagram.
	var g := glow_color()
	var deep := Color(1.0, 0.35, 0.05) if element == "fire" else Color(0.2, 0.5, 1.0)
	var t := Time.get_ticks_msec() / 1000.0
	var center := Vector2(_body_rect.get_center().x, _feet_y + 6.0)
	var r := 175.0
	if _circle_tex != null:
		# Generated rune circle, tinted, flattened onto the floor and slowly turning.
		draw_set_transform(center, t * 0.15, Vector2(1.0, 0.3))
		var tint := g
		tint.a = 0.9 + 0.1 * sin(t * 3.0)
		draw_texture_rect(_circle_tex, Rect2(Vector2(-r * 1.25, -r * 1.25), Vector2(r * 2.5, r * 2.5)), false, tint)
		draw_set_transform(Vector2.ZERO)
		var glow2 := deep
		glow2.a = 0.14
		draw_set_transform(center, 0.0, Vector2(1.0, 0.3))
		draw_circle(Vector2.ZERO, r * 1.35, glow2)
		draw_set_transform(Vector2.ZERO)
		return
	draw_set_transform(center, 0.0, Vector2(1.0, 0.3))
	var fill := deep
	fill.a = 0.16 + 0.05 * sin(t * 3.0)
	draw_circle(Vector2.ZERO, r, fill)
	var ring := g
	ring.a = 0.9
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 96, ring, 5.0, true)
	ring.a = 0.6
	draw_arc(Vector2.ZERO, r * 0.78, 0.0, TAU, 96, ring, 2.5, true)
	var star := PackedVector2Array()
	for i in 5:
		star.append(Vector2.from_angle(t * 0.35 + i * TAU * 2.0 / 5.0 - PI / 2.0) * r * 0.78)
	star.append(star[0])
	draw_polyline(star, ring, 3.0, true)
	for i in 24:
		var a := -t * 0.5 + i * TAU / 24.0
		var len := 16.0 if i % 6 == 0 else 7.0
		draw_line(Vector2.from_angle(a) * (r + 4.0), Vector2.from_angle(a) * (r + 4.0 + len), ring, 2.0, true)
	draw_set_transform(Vector2.ZERO)
	# Soft glow above the circle.
	var glow := deep
	glow.a = 0.12
	draw_set_transform(center, 0.0, Vector2(1.0, 0.3))
	draw_circle(Vector2.ZERO, r * 1.35, glow)
	draw_set_transform(Vector2.ZERO)


func _draw_face() -> void:
	if not _visible_body:
		return
	var g := glow_color()
	var deep := Color(1.0, 0.25, 0.05) if element == "fire" else Color(0.15, 0.45, 1.0)
	var t := Time.get_ticks_msec() / 1000.0
	# Hands: spell orbs, a hot core inside a flickering ball and a slowly turning rune ring.
	for k in 2:
		if not _hands_active[k] or _orb_tex != null:
			continue
		var hp: Vector2 = _hand_pos[k]
		var flicker := 1.0 + 0.12 * sin(t * 17.0 + k * 2.1) + 0.06 * sin(t * 29.0 + k)
		var halo := deep
		halo.a = 0.22
		_face.draw_circle(hp, 58.0 * flicker, halo)
		halo.a = 0.45
		_face.draw_circle(hp, 36.0 * flicker, halo)
		_face.draw_circle(hp, 22.0 * flicker, g)
		_face.draw_circle(hp, 11.0, Color.WHITE.lerp(g, 0.25))
		var ring_c := g
		ring_c.a = 0.85
		var spin := t * (1.6 if k == 0 else -1.3)
		for seg in 6:
			var a0 := spin + seg * TAU / 6.0
			_face.draw_arc(hp, 44.0 * flicker, a0, a0 + TAU / 6.0 * 0.55, 8, ring_c, 3.0, true)
		for seg in 3:
			var a0 := -spin * 0.7 + seg * TAU / 3.0
			var p0 := hp + Vector2.from_angle(a0) * 30.0
			var p1 := hp + Vector2.from_angle(a0 + TAU / 3.0) * 30.0
			_face.draw_line(p0, p1, ring_c, 2.0, true)
	if _shield_up:
		_draw_shield()
	if has_pose_art():
		return
	# Eyes burning inside the hood.
	var eye_dx := 9.0
	var eye_y := _head_pos.y + 4.0
	for sx in [-1.0, 1.0]:
		var e := Vector2(_head_pos.x + sx * eye_dx, eye_y)
		var halo := deep
		halo.a = 0.55
		_face.draw_circle(e, 9.0, halo)
		_face.draw_set_transform(e, 0.0, Vector2(1.0, 0.5))
		_face.draw_circle(Vector2.ZERO, 5.0, Color.WHITE.lerp(g, 0.35))
		_face.draw_set_transform(Vector2.ZERO)


## Shield: a cyber magic circle standing between the wizards, seen at a slant.
func _draw_shield() -> void:
	var center := Vector2(_body_rect.get_center().x + _facing * 150.0, _head_pos.y + 170.0)
	var c := Color(1.0, 0.5, 0.15) if element == "fire" else Color(0.35, 0.7, 1.0)
	var bright := glow_color()
	var t := Time.get_ticks_msec() / 1000.0
	var pulse := 0.5 + 0.5 * sin(t * 6.0)
	var r := 300.0
	if _barrier_tex != null:
		# Crystal barrier standing in front of the wizard, convex side toward the opponent.
		var h := _body_rect.size.y * 1.05
		var w := h * _barrier_tex.get_width() / _barrier_tex.get_height()
		var bx := _body_rect.get_center().x + _facing * (_body_rect.size.x * 0.5 + w * 0.2)
		var tint := Color(1, 1, 1, 0.8 + 0.2 * pulse)
		var glow := c
		glow.a = 0.25 * pulse
		# Forming: scale in from the centre over a quarter second with a bright flash.
		var age := t - _shield_since
		var form := clampf(age / 0.25, 0.0, 1.0)
		form = 1.0 - pow(1.0 - form, 3.0)
		tint = tint.lerp(Color(2.0, 2.0, 2.0, 1.0), (1.0 - form) * 0.8)
		var cy := _feet_y - h * 0.5
		# Mirror with a transform so the flipped copy stays centred on bx.
		_face.draw_set_transform(Vector2(bx, cy), 0.0, Vector2(float(_facing) * form, form))
		var rect := Rect2(Vector2(-w * 0.5, -h * 0.5), Vector2(w, h))
		_face.draw_texture_rect(_barrier_tex, rect.grow(12.0), false, glow)
		_face.draw_texture_rect(_barrier_tex, rect, false, tint)
		_face.draw_set_transform(Vector2.ZERO)
		return
	# The disc faces the opponent, so it appears as a tall narrow ellipse.
	if _circle_tex != null:
		_face.draw_set_transform(center, 0.0, Vector2(0.28, 1.0))
		var tint := bright
		tint.a = 0.85 + 0.15 * pulse
		_face.draw_texture_rect(_circle_tex, Rect2(Vector2(-r, -r), Vector2(r * 2.0, r * 2.0)), false, tint)
		var fill2 := c
		fill2.a = 0.12 + 0.08 * pulse
		_face.draw_circle(Vector2.ZERO, r * 0.95, fill2)
		_face.draw_set_transform(Vector2.ZERO)
		var sheet2 := c
		sheet2.a = 0.12
		_face.draw_line(center + Vector2(0, -r), center + Vector2(0, r), sheet2, 26.0, true)
		return
	_face.draw_set_transform(center, 0.0, Vector2(0.28, 1.0))
	var fill := c
	fill.a = 0.10 + 0.08 * pulse
	_face.draw_circle(Vector2.ZERO, r, fill)
	var ring := c
	ring.a = 0.9
	_face.draw_arc(Vector2.ZERO, r, 0.0, TAU, 96, ring, 6.0, true)
	ring.a = 0.5
	_face.draw_arc(Vector2.ZERO, r * 0.82, 0.0, TAU, 96, ring, 3.0, true)
	_face.draw_arc(Vector2.ZERO, r * 0.55, 0.0, TAU, 64, ring, 2.0, true)
	# Tick marks and rotating rune segments.
	for i in 36:
		var a := i * TAU / 36.0 + t * 0.4
		var len := 22.0 if i % 3 == 0 else 10.0
		_face.draw_line(Vector2.from_angle(a) * (r - len), Vector2.from_angle(a) * r, ring, 2.0, true)
	var seg := bright
	seg.a = 0.85
	for i in 8:
		var a0 := -t * 0.7 + i * TAU / 8.0
		_face.draw_arc(Vector2.ZERO, r * 0.7, a0, a0 + TAU / 8.0 * 0.5, 12, seg, 4.0, true)
	for i in 6:
		var a := t * 1.1 + i * TAU / 6.0
		var p0 := Vector2.from_angle(a) * (r * 0.55)
		var p1 := Vector2.from_angle(a + TAU / 3.0) * (r * 0.55)
		_face.draw_line(p0, p1, seg, 1.5, true)
	_face.draw_set_transform(Vector2.ZERO)
	# Energy sheet behind the disc toward the caster's hand.
	var sheet := c
	sheet.a = 0.12
	_face.draw_line(center + Vector2(0, -r), center + Vector2(0, r), sheet, 26.0, true)
