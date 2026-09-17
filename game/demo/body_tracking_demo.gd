extends Control
## Body tracking debug scene: the Gemini color image with MediaPipe skeletons,
## per-joint depth and XYZ, velocities, player ids, and performance numbers.
## Run with:  godot --path game res://demo/body_tracking_demo.tscn
## In the game: press T.

const BONES := [
	[11, 12], [11, 13], [13, 15], [12, 14], [14, 16], [11, 23], [12, 24], [23, 24],
	[23, 25], [25, 27], [24, 26], [26, 28], [27, 31], [28, 32], [15, 19], [16, 20],
	[0, 11], [0, 12],
]
const PLAYER_COLORS := [Color(1.0, 0.55, 0.15), Color(0.35, 0.7, 1.0), Color(0.6, 1.0, 0.5)]

var _tex: ImageTexture = null
var _last_frame_id := -1
var _last_gesture := ""
var _last_gesture_time := 0.0


func _ready() -> void:
	BodyTracker.gesture.connect(func(p, g): _last_gesture = "P%d %s" % [p.id, g]; _last_gesture_time = Time.get_ticks_msec() / 1000.0)


func _process(_delta: float) -> void:
	var cam := BodyTracker.camera
	if cam != null and cam.is_running():
		var fid: int = cam.get_color_frame_id()
		if fid != _last_frame_id:
			_last_frame_id = fid
			var img: Image = cam.get_color_image()
			if img != null:
				if _tex == null or _tex.get_size() != Vector2(img.get_size()):
					_tex = ImageTexture.create_from_image(img)
				else:
					_tex.update(img)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE or event.keycode == KEY_T:
			get_tree().change_scene_to_file("res://scenes/main.tscn")


func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.05, 0.08))
	var view := Rect2(Vector2(20, 60), Vector2(1280, 720))
	if _tex != null:
		draw_texture_rect(_tex, view, false)
	else:
		draw_rect(view, Color(0.1, 0.1, 0.14))
		draw_string(font, view.position + Vector2(20, 40), "no color frames yet", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1, 0.6, 0.6))
	var scale := view.size / Vector2(1280, 720)
	var cam := BodyTracker.camera
	if cam != null and cam.get_color_width() > 0:
		scale = view.size / Vector2(cam.get_color_width(), cam.get_color_height())

	var players: Array = BodyTracker.players
	for p in players:
		var col: Color = PLAYER_COLORS[(p.id - 1) % PLAYER_COLORS.size()]
		var pts: Array = []
		for name in TrackedPlayer.JOINT_NAMES:
			var j: TrackedJoint = p.joints[name]
			pts.append(view.position + j.image_position * scale)
		for b in BONES:
			var ja: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[b[0]]]
			var jb: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[b[1]]]
			var c := col if (ja.valid and jb.valid) else Color(col, 0.35)
			draw_line(pts[b[0]], pts[b[1]], c, 3.0, true)
		for i in pts.size():
			var j: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[i]]
			var c := col if j.valid else Color(1, 0.3, 0.3)
			if j.depth_inferred:
				c = Color(1, 1, 0.3)
			draw_circle(pts[i], 4.0, c)
			if i in [0, 15, 16, 23, 24, 27, 28]:
				draw_string(font, pts[i] + Vector2(6, -4), "%d z%.2f" % [i, j.position_3d.z], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.9))
		var head_px: Vector2 = pts[0]
		draw_string(font, head_px + Vector2(-40, -30), "PLAYER %d  conf %.2f" % [p.id, p.tracking_confidence], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, col)

	# Right column: numbers.
	var x := 1330.0
	var y := 90.0
	var lines: Array[String] = []
	lines.append("BodyTracker  %s" % BodyTracker.status)
	lines.append("camera %.1f fps   poses %.1f/s   inference %.0f ms" % [BodyTracker.camera_fps, BodyTracker.processor.poses_per_second, BodyTracker.processor.inference_ms])
	lines.append("render %d fps   players %d" % [Engine.get_frames_per_second(), BodyTracker.player_count])
	if BodyTracker.processor.last_error != "":
		lines.append("pose error: " + BodyTracker.processor.last_error)
	lines.append("")
	for p in players:
		lines.append("PLAYER %d   height %.2f m   %s%s%s" % [p.id, p.standing_height,
			"CROUCH " if p.is_crouching else "", "JUMP " if p.is_jumping else "", "ARMS UP " if p.arms_up else ""])
		lines.append("  root  x %.2f  y %.2f  z %.2f   v %.2f m/s" % [p.position.x, p.position.y, p.position.z, p.velocity.length()])
		for side in ["left", "right"]:
			var hnd: TrackedJoint = p.joint(side + "_wrist")
			lines.append("  %s hand  x %.2f  y %.2f  z %.2f   v %.2f m/s %s" % [side, hnd.position_3d.x, hnd.position_3d.y, hnd.position_3d.z, hnd.velocity.length(), "" if hnd.valid else "(invalid)"])
		lines.append("")
	if Time.get_ticks_msec() / 1000.0 - _last_gesture_time < 1.5:
		lines.append("GESTURE  " + _last_gesture)
	for line in lines:
		draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, 570, 16, Color(0.9, 0.95, 1.0))
		y += 22.0
	draw_string(font, Vector2(20, 40), "BODY TRACKING DEMO   (T or Esc: back to the game)   yellow dot = depth carried over, red = invalid", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.8, 0.9, 1.0))
