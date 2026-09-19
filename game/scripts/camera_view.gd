class_name CameraView
extends Control
## The live camera image with the tracked skeletons on top, mirrored like the
## game. The waiting screen, the settings menu and the debug overlay all use it,
## so it keeps running while the game is paused.

const BONES := [
	[11, 12], [11, 13], [13, 15], [12, 14], [14, 16], [11, 23], [12, 24], [23, 24],
	[23, 25], [25, 27], [24, 26], [26, 28], [0, 11], [0, 12],
]
const PLAYER_COLORS := [Color(1.0, 0.55, 0.15), Color(0.35, 0.7, 1.0), Color(0.6, 1.0, 0.5)]

var detailed := false   # joint distances, candidate boxes and confidence, for the debug overlay
var caption := ""       # drawn above the frame

var _tex: ImageTexture = null
var _last_id := -1
var _last_camera: Node = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var cam := BodyTracker.camera
	if cam != _last_camera:
		_last_camera = cam
		_last_id = -1
		_tex = null
	if cam != null and cam.is_running():
		var id: int = cam.get_color_frame_id()
		if id != _last_id:
			_last_id = id
			var image: Image = cam.get_color_image()
			if image != null:
				if _tex == null or _tex.get_size() != Vector2(image.get_size()):
					_tex = ImageTexture.create_from_image(image)
				else:
					_tex.update(image)
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var frame := Rect2(Vector2.ZERO, size)
	draw_rect(frame.grow(4.0), Color(0.0, 0.0, 0.04, 0.8))
	if caption != "":
		draw_string(font, Vector2(-200.0, -12.0), caption, HORIZONTAL_ALIGNMENT_CENTER, size.x + 400.0, 20, Color(0.8, 0.9, 1.0))
	if _tex == null:
		var why := "Looking for a camera" if BodyTracker.camera == null else "Waiting for the first frame"
		draw_string(font, Vector2(0.0, size.y * 0.5 - 8.0), why, HORIZONTAL_ALIGNMENT_CENTER, size.x, 22, Color(1.0, 0.75, 0.6))
		draw_string(font, Vector2(12.0, size.y * 0.5 + 22.0), BodyTracker.status, HORIZONTAL_ALIGNMENT_CENTER, size.x - 24.0, 15, Color(0.75, 0.75, 0.85))
		draw_rect(frame, Color(0.6, 0.9, 1.0, 0.8), false, 2.0)
		return

	# Letterbox the image into the control, whatever the camera's aspect is.
	var image_size := Vector2(_tex.get_size())
	var fit := minf(size.x / image_size.x, size.y / image_size.y)
	var view := Rect2((size - image_size * fit) * 0.5, image_size * fit)
	var mirrored: bool = Settings.mirror
	if mirrored:
		# Flip with the transform: a negative-size rect is not mirrored in place.
		draw_set_transform(Vector2(view.end.x, view.position.y), 0.0, Vector2(-1.0, 1.0))
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, view.size), false)
		draw_set_transform(Vector2.ZERO)
	else:
		draw_texture_rect(_tex, view, false)

	for p in BodyTracker.players:
		if not p.visible:
			continue
		var col: Color = PLAYER_COLORS[(p.id - 1) % PLAYER_COLORS.size()]
		var pts: Array = []
		for joint_name in TrackedPlayer.JOINT_NAMES:
			pts.append(_to_view(p.joints[joint_name].image_position, view, fit, mirrored))
		# Joints the model only guessed at (legs under a desk, hands out of frame)
		# land anywhere, often outside the picture: they are not drawn.
		var inside := view.grow(1.0)
		for bone in BONES:
			var a: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[bone[0]]]
			var b: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[bone[1]]]
			if not _drawable(a, pts[bone[0]], inside) or not _drawable(b, pts[bone[1]], inside):
				continue
			draw_line(pts[bone[0]], pts[bone[1]], col if (a.valid and b.valid) else Color(col, 0.3), 2.0, true)
		for i in pts.size():
			var joint: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[i]]
			if not _drawable(joint, pts[i], inside):
				continue
			draw_circle(pts[i], 3.0, Color(1, 1, 0.3) if joint.depth_inferred else (col if joint.valid else Color(1, 0.3, 0.3)))
		if detailed:
			for i in [15, 16, 0]:
				var joint: TrackedJoint = p.joints[TrackedPlayer.JOINT_NAMES[i]]
				draw_string(font, pts[i] + Vector2(5, -3), "z%.2f" % joint.position_3d.z, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
			draw_string(font, pts[0] + Vector2(-30, -22), "P%d %.2f" % [p.id, p.tracking_confidence], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		else:
			draw_string(font, pts[0] + Vector2(-14, -18), "P%d" % p.id, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)

	if detailed and BodyTracker.processor is RtmPoseProcessor:
		for box in BodyTracker.processor.last_boxes:
			var r: Rect2 = box
			var a := _to_view(r.position, view, fit, mirrored)
			var b := _to_view(r.end, view, fit, mirrored)
			draw_rect(Rect2(Vector2(minf(a.x, b.x), a.y), Vector2(absf(b.x - a.x), b.y - a.y)), Color(1, 1, 1, 0.5), false, 1.0)
	draw_rect(frame, Color(0.6, 0.9, 1.0, 0.8), false, 2.0)


func _drawable(joint: TrackedJoint, at: Vector2, inside: Rect2) -> bool:
	if joint.image_position == Vector2.ZERO:
		return false   # a joint this pose model does not have
	return inside.has_point(at) and (detailed or joint.valid)


func _to_view(pixel: Vector2, view: Rect2, fit: float, mirrored: bool) -> Vector2:
	var x := pixel.x * fit
	return view.position + Vector2(view.size.x - x if mirrored else x, pixel.y * fit)
