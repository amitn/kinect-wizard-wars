class_name DebugOverlay
extends Control
## Press D: shows every body the tracker reports, with silhouette, height, depth
## and hand tips, so thresholds can be tuned against a real room.

var enabled: bool = false:
	set(v):
		enabled = v
		Tracking.set_camera_debug(v)
var _cam_tex: ImageTexture = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func _process(_delta: float) -> void:
	if enabled:
		queue_redraw()


func _draw() -> void:
	if not enabled:
		return
	var font := ThemeDB.fallback_font
	# Camera view (depth + blobs + markers) bottom-left.
	var cam_img := Tracking.get_camera_debug_image()
	if cam_img != null:
		if _cam_tex == null or _cam_tex.get_size() != Vector2(cam_img.get_size()):
			_cam_tex = ImageTexture.create_from_image(cam_img)
		else:
			_cam_tex.update(cam_img)
		var cam_rect := Rect2(Vector2(20, 1080 - 330), Vector2(480, 300))
		draw_rect(cam_rect.grow(4), Color(0, 0, 0, 0.7))
		draw_texture_rect(_cam_tex, cam_rect, false)
		draw_rect(cam_rect, Color(0.6, 0.9, 1.0, 0.8), false, 2.0)
		draw_string(font, cam_rect.position + Vector2(6, -6), "CAMERA  depth %dx%d  cyan=centre yellow=head red=L green=R" % [cam_img.get_width(), cam_img.get_height()], HORIZONTAL_ALIGNMENT_LEFT, 600, 14, Color(0.8, 0.95, 1.0))
	var panel := Rect2(Vector2(1920 - 560, 1080 - 330), Vector2(540, 300))
	draw_rect(panel, Color(0, 0, 0, 0.7))
	draw_rect(panel, Color(0.6, 0.9, 1.0, 0.8), false, 2.0)
	var y := panel.position.y + 26.0
	draw_string(font, Vector2(panel.position.x + 12, y), "TRACKER  %s" % Tracking.source_description(), HORIZONTAL_ALIGNMENT_LEFT, 520, 16, Color(0.8, 0.95, 1.0))
	y += 8.0
	var x := panel.position.x + 12.0
	var bodies: Array = Tracking.bodies
	if bodies.is_empty():
		draw_string(font, Vector2(x, y + 24), "no bodies", HORIZONTAL_ALIGNMENT_LEFT, 500, 16, Color(1, 0.6, 0.6))
	var slot_w := 170.0
	for i in mini(bodies.size(), 3):
		var b: BodyData = bodies[i]
		var sx := x + i * slot_w
		var base := b.joint("SpineBase")
		var head := b.joint("Head")
		var hl := b.joint("HandLeft") - b.joint("SpineShoulder")
		var hr := b.joint("HandRight") - b.joint("SpineShoulder")
		var lines := [
			"id %s  h %.2fm" % [b.id, b.height],
			"x %.2f  z %.2f" % [base.x, base.z],
			"head y %.2f" % head.y,
			"L %.2f %.2f %.2f %s" % [hl.x, hl.y, hl.z, b.hand_left],
			"R %.2f %.2f %.2f %s" % [hr.x, hr.y, hr.z, b.hand_right],
			"hands_up %s" % ("YES" if b.hands_up else "no"),
		]
		var ty := y + 20.0
		for line in lines:
			draw_string(font, Vector2(sx, ty), line, HORIZONTAL_ALIGNMENT_LEFT, slot_w - 6, 13, Color(0.9, 1.0, 0.9))
			ty += 16.0
		if b.has_silhouette():
			var img := b.silhouette
			var tex := ImageTexture.create_from_image(img)
			var h := 150.0
			var w := h * img.get_width() / float(img.get_height())
			var rect := Rect2(Vector2(sx, ty + 4.0), Vector2(minf(w, slot_w - 10.0), h))
			draw_texture_rect(tex, rect, false, Color(0.4, 0.8, 1.0, 0.9))
			# Hand tips projected into the silhouette box: relative to the centroid, meters -> pixels.
			var scale_px := rect.size.y / maxf(b.height, 0.8)
			var c := rect.position + Vector2(b.silhouette_center) * (rect.size / Vector2(img.get_size()))
			for hand in [["HandLeft", Color(1, 0.4, 0.4)], ["HandRight", Color(0.4, 1, 0.4)]]:
				var rel := b.joint(hand[0]) - base
				var p := c + Vector2(rel.x, -rel.y) * scale_px
				draw_circle(p, 5.0, hand[1])
