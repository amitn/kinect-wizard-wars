extends Node
## Autoload "Tracking". Publishes player skeleton frames as BodyData from
## whichever source is available:
##   1. the OrbbecCamera GDExtension (extension/), reading the depth camera directly, or
##   2. UDP packets from tools/mock_bridge.py (or any bridge speaking the same JSON).
## Both sources produce the same body dictionaries, so the game never cares.

signal frame_received(bodies: Array)

const DEFAULT_PORT := 7777
const TIMEOUT_SEC := 1.0
const CAMERA_RETRY_SEC := 3.0

var port: int = DEFAULT_PORT
var bodies: Array[BodyData] = []
var packets_received: int = 0
var last_packet_time: float = -100.0
var source: String = "none"   # "camera", "udp" or "none"

var _udp := PacketPeerUDP.new()
var _camera: Node = null
var _camera_retry_at := 0.0
var _tracklog := false        # --tracklog: print a body summary twice a second
var _tracklog_next := 0.0


func _ready() -> void:
	port = _port_from_cmdline()
	var err := _udp.bind(port, "0.0.0.0")
	if err != OK:
		push_error("Tracking: could not bind UDP port %d (error %d)" % [port, err])
	else:
		print("Tracking: listening for bridge frames on UDP port %d" % port)

	for arg in OS.get_cmdline_user_args():
		if arg == "--tracklog":
			_tracklog = true
	if ClassDB.class_exists("OrbbecCamera"):
		print("Tracking: OrbbecCamera extension loaded")
		_camera = ClassDB.instantiate("OrbbecCamera")
		add_child(_camera)
		_camera.frame_received.connect(_on_raw_frame.bind("camera"))
		_try_start_camera()
	else:
		print("Tracking: OrbbecCamera extension not loaded, using UDP only")


## Reads `--tracking-port=<n>` (or `--tracking-port <n>`) from the command line.
## Godot keeps arguments after `--` in get_cmdline_user_args() and the rest in
## get_cmdline_args(), so both are checked. Falls back to DEFAULT_PORT.
func _port_from_cmdline() -> int:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for i in args.size():
		var arg: String = args[i]
		var value := ""
		if arg.begins_with("--tracking-port="):
			value = arg.get_slice("=", 1)
		elif arg == "--tracking-port" and i + 1 < args.size():
			value = args[i + 1]
		else:
			continue
		if value.is_valid_int() and int(value) > 0 and int(value) < 65536:
			print("Tracking: UDP port %s from the command line" % value)
			return int(value)
		push_warning("Tracking: ignoring invalid --tracking-port value '%s'" % value)
	return DEFAULT_PORT


## True while frames keep arriving from any source.
func is_connected_to_source() -> bool:
	return Time.get_ticks_msec() / 1000.0 - last_packet_time < TIMEOUT_SEC


func has_camera() -> bool:
	return _camera != null and _camera.is_running()


func is_background_ready() -> bool:
	return _camera == null or not _camera.is_running() or _camera.is_background_ready()


## Debug image from the camera extension (depth + blobs + markers), or null.
func get_camera_debug_image() -> Image:
	if _camera == null or not _camera.is_running():
		return null
	return _camera.get_debug_image()


func set_camera_debug(enabled: bool) -> void:
	if _camera != null:
		_camera.set_debug_enabled(enabled)


## Re-learn the empty room. Players should step out of view for a second.
func learn_background() -> void:
	if _camera != null and _camera.is_running():
		_camera.learn_background()
		print("Tracking: re-learning background")


func source_description() -> String:
	if has_camera():
		if not _camera.is_background_ready():
			return "Camera: %s  -  learning the empty room, stay out of view" % _camera.get_device_name()
		return "Camera: %s (%d bodies)" % [_camera.get_device_name(), bodies.size()]
	if not is_connected_to_source():
		if _camera != null:
			return "No camera (%s)  -  or run tools/mock_bridge.py" % _camera.get_last_error()
		return "No tracking source  -  run tools/mock_bridge.py"
	return "UDP bridge on port %d (%d bodies)" % [port, bodies.size()]


func _try_start_camera() -> void:
	if _camera == null or _camera.is_running():
		return
	if _camera.start():
		print("Tracking: using %s" % _camera.get_device_name())
	else:
		print("Tracking: no camera: %s" % _camera.get_last_error())
	_camera_retry_at = Time.get_ticks_msec() / 1000.0 + CAMERA_RETRY_SEC


func _process(_delta: float) -> void:
	if _camera != null and not _camera.is_running() and Time.get_ticks_msec() / 1000.0 >= _camera_retry_at:
		_try_start_camera()

	# Drain the socket and keep only the newest packet; stale frames are useless.
	var latest := PackedByteArray()
	var got_packet := false
	while _udp.get_available_packet_count() > 0:
		latest = _udp.get_packet()
		got_packet = true
	if not got_packet:
		return
	# The camera wins while it is delivering frames.
	if source == "camera" and is_connected_to_source():
		return

	var parsed = JSON.parse_string(latest.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var raw_bodies = parsed.get("bodies", [])
	if typeof(raw_bodies) != TYPE_ARRAY:
		return
	_on_raw_frame(raw_bodies, "udp")


func _on_raw_frame(raw_bodies: Array, from_source: String) -> void:
	packets_received += 1
	last_packet_time = Time.get_ticks_msec() / 1000.0
	source = from_source

	var new_bodies: Array[BodyData] = []
	for raw in raw_bodies:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var body := BodyData.new()
		if body.load_from(raw):
			new_bodies.append(body)
	bodies = new_bodies
	frame_received.emit(bodies)
	if _tracklog and last_packet_time >= _tracklog_next:
		_tracklog_next = last_packet_time + 0.5
		var parts: Array[String] = []
		for b in bodies:
			var base := b.joint("SpineBase")
			var hl := b.joint("HandLeft") - b.joint("SpineShoulder")
			var hr := b.joint("HandRight") - b.joint("SpineShoulder")
			parts.append("id=%s h=%.2f x=%.2f z=%.2f L=(%.2f,%.2f,%.2f)%s R=(%.2f,%.2f,%.2f)%s%s" % [
				b.id, b.height, base.x, base.z, hl.x, hl.y, hl.z, "*" if b.hand_left == "tracked" else "",
				hr.x, hr.y, hr.z, "*" if b.hand_right == "tracked" else "", " UP" if b.hands_up else ""])
		print("tracklog t=%.1f n=%d  %s" % [last_packet_time, bodies.size(), "  |  ".join(parts)])
