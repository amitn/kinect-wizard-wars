class_name Wizard
extends Node2D
## One player: health, mana, shield, the tracked skeleton and how it is drawn.

signal died

@export var element: String = "fire"
@export var facing: int = 1          # +1 casts toward the right, -1 toward the left
@export var mirror_x: bool = true    # true = screen behaves like a mirror

const MAX_HP := 100.0
const MAX_MANA := 100.0
const MANA_REGEN := 12.0        # per second
const SHIELD_DRAIN := 20.0      # per second while the shield is up
const SHIELD_MIN_MANA := 10.0   # cannot raise a shield below this
const PIXELS_PER_METER := 320.0
const GROUND_Y := 940.0
const BODY_TIMEOUT := 1.5       # seconds without a frame before the player counts as lost

var hp := MAX_HP
var mana := MAX_MANA
var shield_up := false
var body: BodyData = null
var body_id: String = ""
var body_seen_at := -100.0
var gestures := GestureRecognizer.new()

var _hit_flash := 0.0
var _cast_flash := 0.0
var fx: WizardFX
var outcome := ""   # "", "win" or "lose" once the round is decided
var _origin := Vector2(0.0, GROUND_Y - 0.9 * PIXELS_PER_METER)


func _ready() -> void:
	gestures.shield_changed.connect(set_shield)
	fx = WizardFX.new()
	fx.element = element
	fx.mirror_x = mirror_x
	add_child(fx)


func color() -> Color:
	return Color(1.0, 0.45, 0.12) if element == "fire" else Color(0.3, 0.65, 1.0)


func glow_color() -> Color:
	return Color(1.0, 0.85, 0.3) if element == "fire" else Color(0.7, 0.95, 1.0)


func display_name() -> String:
	return "FIRE WIZARD" if element == "fire" else "WATER WIZARD"


func is_tracked() -> bool:
	return body != null


func opponent_element() -> String:
	return "water" if element == "fire" else "fire"


# -- Body tracking ----------------------------------------------------------

func set_body(new_body: BodyData, now: float) -> void:
	body = new_body
	body_id = new_body.id
	body_seen_at = now
	gestures.update(new_body, now)
	_update_origin()
	queue_redraw()


func clear_body() -> void:
	body = null
	body_id = ""
	gestures.reset()
	queue_redraw()


func check_timeout(now: float) -> void:
	if body != null and now - body_seen_at > BODY_TIMEOUT:
		clear_body()


# -- Resources ---------------------------------------------------------------

func reset_round() -> void:
	outcome = ""
	hp = MAX_HP
	mana = MAX_MANA
	shield_up = false
	_hit_flash = 0.0
	_cast_flash = 0.0


func _process(delta: float) -> void:
	if shield_up:
		mana = maxf(0.0, mana - SHIELD_DRAIN * delta)
		if mana <= 0.0:
			shield_up = false
	else:
		mana = minf(MAX_MANA, mana + MANA_REGEN * delta)
	_hit_flash = maxf(0.0, _hit_flash - delta)
	_cast_flash = maxf(0.0, _cast_flash - delta)
	_update_fx()
	queue_redraw()


func _update_fx() -> void:
	if fx == null:
		return
	fx.mirror_x = mirror_x
	if body == null:
		fx.hide_body()
		return
	var joints := {}
	for joint_name in body.joints.keys():
		joints[joint_name] = joint_to_local(joint_name)
	var sil_rect := Rect2()
	if body.has_silhouette():
		sil_rect = _silhouette_rect()
	var feet_y := maxf(joint_to_local("FootLeft").y, joint_to_local("FootRight").y)
	fx.update_look(body.silhouette if body.has_silhouette() else null, body.silhouette_center, sil_rect, joints,
		joint_to_local("Head"), joint_to_local("HandLeft"), joint_to_local("HandRight"), feet_y,
		shield_up, facing, _hit_flash, _cast_flash, [_hand_active("HandLeft"), _hand_active("HandRight")], outcome)


## A hand is "active" when raised to shoulder height or pushed out in front.
func _hand_active(joint_name: String) -> bool:
	var rel := body.joint(joint_name) - body.joint("SpineShoulder")
	return rel.y > -0.25 or rel.z < -0.2


## Local rectangle the silhouette covers: centroid pixel on the SpineBase, pixel
## height matching the tracked height in meters. Un-mirrored; WizardFX flips it.
func _silhouette_rect() -> Rect2:
	var img := body.silhouette
	var real_height := body.joint("Head").y - body.joint("FootLeft").y
	if body.height > 0.0:
		real_height = maxf(real_height, body.height)
	real_height = clampf(real_height, 0.8, 2.6)
	var px_per_pixel := real_height * PIXELS_PER_METER / float(img.get_height())
	var size := Vector2(img.get_width(), img.get_height()) * px_per_pixel
	var anchor := joint_to_local("SpineBase")
	var center := Vector2(body.silhouette_center) * px_per_pixel
	var top_left := anchor - center
	if mirror_x:
		top_left.x = anchor.x - (size.x - center.x)
	return Rect2(top_left, size)


func set_shield(active: bool) -> void:
	if active and mana < SHIELD_MIN_MANA:
		return
	shield_up = active


func can_cast(cost: float) -> bool:
	return hp > 0.0 and mana >= cost


func spend_mana(cost: float) -> void:
	mana = maxf(0.0, mana - cost)
	_cast_flash = 0.25


func drain_mana(amount: float) -> void:
	mana = maxf(0.0, mana - amount)
	if mana <= 0.0:
		shield_up = false


func take_damage(amount: float) -> void:
	if hp <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	_hit_flash = 0.4
	if hp <= 0.0:
		died.emit()


# -- Screen mapping ----------------------------------------------------------

## Joint position in this node's local space. Hips are anchored so the lower foot
## rests on GROUND_Y; the whole figure is scaled by PIXELS_PER_METER.
func joint_to_local(joint_name: String) -> Vector2:
	if body == null:
		return _origin
	var rel := body.joint(joint_name) - body.joint("SpineBase")
	var sx := rel.x * PIXELS_PER_METER * (-1.0 if mirror_x else 1.0)
	var sy := -rel.y * PIXELS_PER_METER
	return _origin + Vector2(sx, sy)


func hand_global_position(hand: String) -> Vector2:
	if body == null:
		return to_global(Vector2(facing * 120.0, 560.0))
	var joint_name := "HandLeft" if hand == "left" else "HandRight"
	return to_global(joint_to_local(joint_name))


func chest_global_position() -> Vector2:
	if body == null:
		return to_global(Vector2(0.0, 560.0))
	return to_global(joint_to_local("SpineShoulder"))


func _update_origin() -> void:
	var base := body.joint("SpineBase")
	var foot_drop := base.y - minf(body.joint("FootLeft").y, body.joint("FootRight").y)
	foot_drop = clampf(foot_drop, 0.6, 1.2)
	_origin = Vector2(0.0, GROUND_Y - foot_drop * PIXELS_PER_METER)


# -- Drawing -----------------------------------------------------------------
# The tracked body is drawn by WizardFX (aura, robe, orbs, eyes, shield).

func _draw() -> void:
	if body == null:
		_draw_placeholder()


func _draw_placeholder() -> void:
	var c := color()
	c.a = 0.25
	var top := Vector2(0.0, GROUND_Y - 520.0)
	draw_circle(top, 36.0, c)
	draw_line(top + Vector2(0, 40), Vector2(0, GROUND_Y - 250.0), c, 8.0)
	draw_line(Vector2(-110, GROUND_Y - 380.0), Vector2(110, GROUND_Y - 380.0), c, 8.0)
	draw_line(Vector2(0, GROUND_Y - 250.0), Vector2(-70, GROUND_Y), c, 8.0)
	draw_line(Vector2(0, GROUND_Y - 250.0), Vector2(70, GROUND_Y), c, 8.0)
	var font := ThemeDB.fallback_font
	var label := "WAITING FOR %s" % display_name()
	draw_string(font, Vector2(-300.0, GROUND_Y + 42.0), label, HORIZONTAL_ALIGNMENT_CENTER, 600.0, 28, c.lightened(0.4))
