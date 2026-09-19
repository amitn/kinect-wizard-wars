extends Node
## Autoload "Settings": the player's options, kept in user://settings.cfg.
##
##   Settings.camera_mode                     # "auto", "depth" or "rgb"
##   Settings.set_value("fullscreen", false)  # applies, saves, emits changed("fullscreen")
##
## Command-line overrides (after `--`) win over the file and are never saved:
##   --camera=auto|depth|rgb   --webcam=<index>   --windowed   --fullscreen
##   --no-save  keeps this run from writing the file (tests)

signal changed(key: String)

const PATH := "user://settings.cfg"
const SECTION := "settings"

const CAMERA_AUTO := "auto"     # the depth camera when one is plugged in, a webcam otherwise
const CAMERA_DEPTH := "depth"   # RGB + depth: Orbbec Gemini 2 and relatives
const CAMERA_RGB := "rgb"       # any ordinary webcam
const CAMERA_MODES := [CAMERA_AUTO, CAMERA_DEPTH, CAMERA_RGB]

const DEFAULTS := {
	"camera_mode": CAMERA_AUTO,
	"webcam_name": "",        # webcams are remembered by name: indices move when one is plugged in
	"webcam_index": 0,
	"webcam_fov": 62.0,       # horizontal field of view assumed for a webcam, degrees
	"mirror": true,           # the screen behaves like a mirror
	"sensitivity": 1,         # gestures: 0 low, 1 normal, 2 high
	"fullscreen": true,
	"camera_preview": true,   # show the camera while waiting for players
}

var _values: Dictionary = DEFAULTS.duplicate()
var _overrides: Dictionary = {}
var _persist := true

var camera_mode: String:
	get: return get_value("camera_mode")
var webcam_name: String:
	get: return get_value("webcam_name")
var webcam_index: int:
	get: return get_value("webcam_index")
var webcam_fov: float:
	get: return get_value("webcam_fov")
var mirror: bool:
	get: return get_value("mirror")
var sensitivity: int:
	get: return get_value("sensitivity")
var fullscreen: bool:
	get: return get_value("fullscreen")
var camera_preview: bool:
	get: return get_value("camera_preview")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--camera="):
			var mode := arg.get_slice("=", 1)
			if mode in CAMERA_MODES:
				_overrides["camera_mode"] = mode
			else:
				push_warning("Settings: ignoring --camera=%s (auto, depth or rgb)" % mode)
		elif arg.begins_with("--webcam="):
			_overrides["webcam_index"] = maxi(0, int(arg.get_slice("=", 1)))
			_overrides["webcam_name"] = ""
		elif arg == "--windowed":
			_overrides["fullscreen"] = false
		elif arg == "--fullscreen":
			_overrides["fullscreen"] = true
		elif arg == "--no-save":
			_persist = false
	_apply_window()


func get_value(key: String) -> Variant:
	if _overrides.has(key):
		return _overrides[key]
	return _values.get(key, DEFAULTS.get(key))


## True when the command line set this key for the run.
func is_overridden(key: String) -> bool:
	return _overrides.has(key)


## Changing a value in the menu also drops a command-line override of it, so
## what the player picks is what they get.
func set_value(key: String, value: Variant) -> void:
	if not DEFAULTS.has(key):
		push_warning("Settings: unknown key '%s'" % key)
		return
	_overrides.erase(key)
	if typeof(_values.get(key)) == typeof(value) and _values.get(key) == value:
		return
	_values[key] = value
	_save()
	if key == "fullscreen":
		_apply_window()
	changed.emit(key)


## Gesture thresholds are divided by this: above 1 a smaller, slower move counts.
func sensitivity_factor() -> float:
	return [0.8, 1.0, 1.3][clampi(sensitivity, 0, 2)]


func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


func _apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)


func _load() -> void:
	var file := ConfigFile.new()
	if file.load(PATH) != OK:
		return
	for key in DEFAULTS:
		var value: Variant = file.get_value(SECTION, key, DEFAULTS[key])
		# A hand-edited file with the wrong type falls back to the default.
		if typeof(value) == typeof(DEFAULTS[key]):
			_values[key] = value
		elif typeof(DEFAULTS[key]) == TYPE_FLOAT and typeof(value) == TYPE_INT:
			_values[key] = float(value)
	if not (_values["camera_mode"] in CAMERA_MODES):
		_values["camera_mode"] = CAMERA_AUTO


func _save() -> void:
	if not _persist:
		return
	var file := ConfigFile.new()
	for key in DEFAULTS:
		file.set_value(SECTION, key, _values[key])
	var err := file.save(PATH)
	if err != OK:
		push_warning("Settings: could not save %s (%s)" % [PATH, error_string(err)])
