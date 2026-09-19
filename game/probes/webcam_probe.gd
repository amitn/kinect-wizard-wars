extends SceneTree
## Lists the webcams and grabs a second of frames from each (or from --device=N):
##
##   godot --headless --path game --script res://probes/webcam_probe.gd -- --no-camera [--device=N] [--mode=WxH] [--out=<dir>] [--require]
##
## --out saves the last frame of every camera as webcam_<n>.png. --require makes
## the exit code 1 unless a camera delivered real (not black) frames, which is
## how CI checks the V4L2 backend against a loopback device.

func _init() -> void:
	var out_dir := ""
	var only := -1
	var required := false
	var seconds := 1.5
	var mode := Vector2i.ZERO
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.get_slice("=", 1)
		elif arg.begins_with("--device="):
			only = int(arg.get_slice("=", 1))
		elif arg.begins_with("--seconds="):
			seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--mode="):
			var wh := arg.get_slice("=", 1).split("x")
			if wh.size() == 2:
				mode = Vector2i(int(wh[0]), int(wh[1]))
		elif arg == "--require":
			required = true
	if not ClassDB.class_exists("WebcamCamera"):
		print("webcam probe: this extension build has no WebcamCamera")
		quit(1 if required else 0)
		return
	var cam: Node = ClassDB.instantiate("WebcamCamera")
	var names: PackedStringArray = cam.list_devices()
	print("webcam probe: %d camera(s)" % names.size())
	for i in names.size():
		print("  [%d] %s" % [i, names[i]])
	var good := 0
	for i in names.size():
		if only >= 0 and i != only:
			continue
		cam.set_device(i)
		if mode != Vector2i.ZERO:
			cam.set_mode(mode.x, mode.y, 30)
		var t0 := Time.get_ticks_msec()
		if not cam.start():
			print("  [%d] start failed: %s" % [i, cam.get_last_error()])
			continue
		print("  [%d] opened %s in %d ms" % [i, cam.get_device_name(), Time.get_ticks_msec() - t0])
		var first_id := -1
		var last_id := -1
		var first_at := 0
		var image: Image = null
		var until := Time.get_ticks_msec() + int(seconds * 1000.0) + 1500
		while Time.get_ticks_msec() < until and cam.is_running():
			OS.delay_msec(10)
			var id: int = cam.get_color_frame_id()
			if id != last_id and id > 0:
				if first_id < 0:
					first_id = id
					first_at = Time.get_ticks_msec()
					until = first_at + int(seconds * 1000.0)
				last_id = id
		image = cam.get_color_image()
		var span := maxf(0.001, (Time.get_ticks_msec() - first_at) / 1000.0)
		if image == null or first_id < 0:
			print("  [%d] no frames (%s)" % [i, cam.get_last_error()])
		else:
			var mean := _mean_luma(image)
			var intr: PackedFloat32Array = cam.get_intrinsics()
			print("  [%d] %dx%d  %.1f fps  mean luma %.3f  fx %.0f  has_depth=%s" % [i, image.get_width(), image.get_height(),
					(last_id - first_id) / span, mean, intr[0], cam.has_depth()])
			if mean > 0.02:
				good += 1
			if out_dir != "":
				DirAccess.make_dir_recursive_absolute(out_dir)
				var path := out_dir.path_join("webcam_%d.png" % i)
				print("  [%d] saved %s (%s)" % [i, path, error_string(image.save_png(path))])
		cam.stop()
	cam.free()
	print("webcam probe: %d camera(s) delivered frames" % good)
	quit(1 if required and good == 0 else 0)


func _mean_luma(image: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, image.get_height(), 16):
		for x in range(0, image.get_width(), 16):
			sum += image.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(1.0, n)
