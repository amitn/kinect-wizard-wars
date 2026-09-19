class_name SettingsMenu
extends CanvasLayer
## The Esc menu: camera choice with a live preview, play options, quit.
## Pauses the game while it is open; tracking keeps running so a camera change
## can be seen working before the menu is closed. Mouse, or arrows + Enter.

signal closed()
signal restart_requested()

const ACCENT := Color(0.62, 0.45, 1.0)
const TEXT := Color(0.9, 0.9, 1.0)
const CAMERA_LABELS := {
	Settings.CAMERA_AUTO: "Auto  (depth camera if connected, else webcam)",
	Settings.CAMERA_DEPTH: "RGB + depth  (Orbbec Gemini 2)",
	Settings.CAMERA_RGB: "RGB  (any webcam)",
}
const SENSITIVITY_LABELS := ["Low  (big, fast moves)", "Normal", "High  (small moves count)"]

var _camera_mode: OptionButton
var _webcam: OptionButton
var _mirror: CheckButton
var _sensitivity: OptionButton
var _fullscreen: CheckButton
var _preview_toggle: CheckButton
var _status: Label
var _resume: Button
var _webcam_names := PackedStringArray()
var _filling := false   # true while controls are being loaded from Settings


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	_load_values()
	visible = true
	get_tree().paused = true
	_resume.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	get_tree().paused = false
	closed.emit()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()


func _process(_delta: float) -> void:
	if visible:
		_status.text = Tracking.source_description()


# -- Values -------------------------------------------------------------------

func _load_values() -> void:
	_filling = true
	_camera_mode.select(Settings.CAMERA_MODES.find(Settings.camera_mode))
	_mirror.button_pressed = Settings.mirror
	_sensitivity.select(clampi(Settings.sensitivity, 0, 2))
	_fullscreen.button_pressed = Settings.fullscreen
	_preview_toggle.button_pressed = Settings.camera_preview
	_fill_webcams()
	_filling = false


func _fill_webcams() -> void:
	_webcam_names = BodyTracker.list_webcams()
	_webcam.clear()
	for webcam_name in _webcam_names:
		_webcam.add_item(webcam_name)
	if _webcam_names.is_empty():
		_webcam.add_item("no webcam found")
		_webcam.disabled = true
		return
	_webcam.select(BodyTracker.preferred_webcam(_webcam_names))
	_webcam.disabled = Settings.camera_mode == Settings.CAMERA_DEPTH


func _on_camera_mode(index: int) -> void:
	if _filling:
		return
	Settings.set_value("camera_mode", Settings.CAMERA_MODES[index])
	_webcam.disabled = _webcam_names.is_empty() or Settings.camera_mode == Settings.CAMERA_DEPTH


func _on_webcam(index: int) -> void:
	if _filling or index < 0 or index >= _webcam_names.size():
		return
	Settings.set_value("webcam_name", _webcam_names[index])
	Settings.set_value("webcam_index", index)


func _on_toggle(pressed: bool, key: String) -> void:
	if not _filling:
		Settings.set_value(key, pressed)


func _on_sensitivity(index: int) -> void:
	if not _filling:
		Settings.set_value("sensitivity", index)


# -- Layout -------------------------------------------------------------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.01, 0.0, 0.04, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.theme = _make_theme()
	panel.add_theme_stylebox_override("panel", _box(Color(0.04, 0.03, 0.1, 0.96), ACCENT, 3, 18, 36))
	panel.custom_minimum_size = Vector2(1280, 0)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 22)
	panel.add_child(column)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 54)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_outline_color", Color(ACCENT, 0.8))
	title.add_theme_constant_override("outline_size", 10)
	column.add_child(title)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 36)
	column.add_child(body)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 16)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(grid)

	_camera_mode = _option(grid, "Camera", Settings.CAMERA_MODES.map(func(m): return CAMERA_LABELS[m]))
	_camera_mode.item_selected.connect(_on_camera_mode)
	_webcam = _option(grid, "Webcam", [])
	_webcam.item_selected.connect(_on_webcam)
	_mirror = _toggle(grid, "Mirror the players", "mirror")
	_sensitivity = _option(grid, "Gesture sensitivity", SENSITIVITY_LABELS)
	_sensitivity.item_selected.connect(_on_sensitivity)
	_fullscreen = _toggle(grid, "Fullscreen  (F11)", "fullscreen")
	_preview_toggle = _toggle(grid, "Show the camera while waiting", "camera_preview")

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 10)
	body.add_child(side)
	var view := CameraView.new()
	view.custom_minimum_size = Vector2(440, 330)
	side.add_child(view)
	_status = Label.new()
	_status.custom_minimum_size = Vector2(440, 84)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 17)
	_status.add_theme_color_override("font_color", Color(0.7, 0.75, 0.9))
	side.add_child(_status)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	column.add_child(buttons)
	_resume = _button(buttons, "Resume  (Esc)", close)
	_button(buttons, "Rescan cameras", func():
		BodyTracker.rescan()
		_load_values())
	_button(buttons, "Restart round", func():
		close()
		restart_requested.emit())
	_button(buttons, "Quit game", func(): get_tree().quit())

	var about := Label.new()
	about.text = "Wizard Wars %s   -   Godot Engine, RTMPose (MMPose), ONNX Runtime, OrbbecSDK, MediaPipe: see THIRD_PARTY_NOTICES.md" % Settings.version()
	about.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	about.add_theme_font_size_override("font_size", 15)
	about.add_theme_color_override("font_color", Color(0.55, 0.55, 0.72))
	column.add_child(about)


func _row_label(grid: GridContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", TEXT)
	grid.add_child(label)


func _option(grid: GridContainer, text: String, items: Array) -> OptionButton:
	_row_label(grid, text)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(520, 52)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.clip_text = true
	option.fit_to_longest_item = false
	for item in items:
		option.add_item(item)
	grid.add_child(option)
	return option


func _toggle(grid: GridContainer, text: String, key: String) -> CheckButton:
	_row_label(grid, text)
	var toggle := CheckButton.new()
	toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	toggle.toggled.connect(_on_toggle.bind(key))
	grid.add_child(toggle)
	return toggle


func _button(parent: Control, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(240, 60)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _box(fill: Color, border: Color, border_px: int, radius: int, margin: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(border_px)
	box.set_corner_radius_all(radius)
	box.set_content_margin_all(margin)
	return box


func _make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 24
	var normal := _box(Color(0.1, 0.08, 0.2, 0.95), Color(ACCENT, 0.45), 2, 10, 12)
	var hover := _box(Color(0.16, 0.12, 0.32, 0.95), Color(ACCENT, 0.9), 2, 10, 12)
	var pressed := _box(Color(0.24, 0.16, 0.46, 0.95), Color.WHITE, 2, 10, 12)
	var focus := _box(Color(0, 0, 0, 0), Color(1.0, 0.85, 0.4), 3, 10, 12)
	var disabled := _box(Color(0.07, 0.07, 0.1, 0.8), Color(0.3, 0.3, 0.4, 0.5), 2, 10, 12)
	for type in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", type, normal)
		theme.set_stylebox("hover", type, hover)
		theme.set_stylebox("pressed", type, pressed)
		theme.set_stylebox("focus", type, focus)
		theme.set_stylebox("disabled", type, disabled)
		theme.set_color("font_color", type, TEXT)
		theme.set_color("font_hover_color", type, Color.WHITE)
		theme.set_color("font_focus_color", type, Color.WHITE)
		theme.set_color("font_disabled_color", type, Color(0.5, 0.5, 0.6))
	theme.set_stylebox("focus", "CheckButton", focus)
	theme.set_stylebox("panel", "PopupMenu", _box(Color(0.06, 0.05, 0.14, 0.98), Color(ACCENT, 0.8), 2, 8, 8))
	theme.set_stylebox("hover", "PopupMenu", _box(Color(0.24, 0.16, 0.46, 0.95), Color(0, 0, 0, 0), 0, 6, 4))
	theme.set_color("font_color", "PopupMenu", TEXT)
	theme.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	theme.set_constant("v_separation", "PopupMenu", 12)
	return theme
