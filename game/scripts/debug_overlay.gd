class_name DebugOverlay
extends Control
## Press D: shows every body the tracker reports, with silhouette, height, depth
## and hand tips, so thresholds can be tuned against a real room.

var enabled: bool = false:
	set(v):
		enabled = v
		Tracking.set_camera_debug(v)
var _cam_tex: ImageTexture = null
var _color_tex: ImageTexture = null
var _last_color_id := -1
var wizards: Array = []   # set by Main: the Wizard nodes, to draw the mapped joints over them

const MP_BONES := [
	[11, 12], [11, 13], [13, 15], [12, 14], [14, 16], [11, 23], [12, 24], [23, 24],
	[23, 25], [25, 27], [24, 26], [26, 28], [27, 31], [28, 32], [15, 19], [16, 20], [0, 11], [0, 12],
]
const PLAYER_COLORS := [Color(1.0, 0.55, 0.15), Color(0.35, 0.7, 1.0), Color(0.6, 1.0, 0.5)]


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
	# Pose view: the color image with MediaPipe skeletons, bottom-left.
	var pose_drawn := false
	var cam := BodyTracker.camera
	if cam != null and cam.is_running() and BodyTracker.processor.available:
		var fid: int = cam.get_color_frame_id()
		if fid != _last_color_id:
			_last_color_id = fid
			var img: Image = cam.get_color_image()
			if img != null:
				if _color_tex == null or _color_tex.get_size() != Vector2(img.get_size()):
					_color_tex = ImageTexture.create_from_image(img)
				else:
					_color_tex.update(img)
		if _color_tex != null:
			var pose_rect := Rect2(Vector2(20, 1080 - 400), Vector2(640, 360))
			draw_rect(pose_rect.grow(4), Color(0, 0, 0, 0.7))
			draw_texture_rect(_color_tex, pose_rect, false)
			var sc := pose_rect.size / Vector2(_color_tex.get_size())
			for p in BodyTracker.players:
				if not p.visible:
					continue
				var col: Color = PLAYER_COLORS[(p.id - 1) % PLAYER_COLORS.size()]
				var pts: Array = []
				for jn in TrackedPlayer.JOINT_NAMES:
					pts.append(pose_rect.position + p.joints[jn].image_position * sc)
				for b in MP_BONES:
					var ja: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[b[0]]]
					var jb: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[b[1]]]
					draw_line(pts[b[0]], pts[b[1]], col if (ja.valid and jb.valid) else Color(col, 0.3), 2.0, true)
				for i in pts.size():
					var j: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[i]]
					draw_circle(pts[i], 3.0, Color(1, 1, 0.3) if j.depth_inferred else (col if j.valid else Color(1, 0.3, 0.3)))
				for i in [15, 16, 0]:
					var j: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[i]]
					draw_string(font, pts[i] + Vector2(5, -3), "z%.2f" % j.position_3d.z, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
				draw_string(font, pts[0] + Vector2(-30, -22), "P%d %.2f" % [p.id, p.tracking_confidence], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
			draw_rect(pose_rect, Color(0.6, 0.9, 1.0, 0.8), false, 2.0)
			draw_string(font, pose_rect.position + Vector2(6, -6), "POSE  %.0f/s  %.0f ms   yellow = depth carried over, red = low confidence" % [BodyTracker.processor.poses_per_second, BodyTracker.processor.inference_ms], HORIZONTAL_ALIGNMENT_LEFT, 640, 14, Color(0.8, 0.95, 1.0))
			pose_drawn = true

	# Mapped joints over the wizards in the arena: what the game actually uses.
	for w in wizards:
		if w == null or w.body == null:
			continue
		var wc: Color = w.color().lightened(0.4)
		for bone in BodyData.BONES:
			if w.body.has_joint(bone[0]) and w.body.has_joint(bone[1]):
				draw_line(w.to_global(w.joint_to_local(bone[0])), w.to_global(w.joint_to_local(bone[1])), Color(wc, 0.85), 2.0, true)
		for jn in w.body.joints.keys():
			var gp: Vector2 = w.to_global(w.joint_to_local(jn))
			draw_circle(gp, 4.0, wc)
		for jn in ["HandLeft", "HandRight", "Head", "SpineShoulder"]:
			if w.body.has_joint(jn):
				var gp: Vector2 = w.to_global(w.joint_to_local(jn))
				var rel: Vector3 = w.body.joint(jn) - w.body.joint("SpineShoulder")
				draw_string(font, gp + Vector2(8, -6), "%s %.2f %.2f %.2f" % [jn, rel.x, rel.y, rel.z], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)

	# Depth-blob view (fallback tracker) when there is no pose view.
	var cam_img: Image = null if pose_drawn else Tracking.get_camera_debug_image()
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
