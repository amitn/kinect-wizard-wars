extends SceneTree
## Lists the color profiles and measures the frame rate for a few color modes.
func _init() -> void:
	var cam = ClassDB.instantiate("OrbbecCamera")
	get_root().add_child(cam)
	print("profiles: ", cam.get_color_profiles())
	var modes := [[1280, 720, 30, "rgb"], [1280, 720, 30, "mjpg"], [640, 360, 30, "rgb"], [1280, 720, 30, "yuyv"], [0, 0, 30, "any"]]
	for m in modes:
		cam.set_color_mode(m[0], m[1], m[2], m[3])
		cam.set_sdk_log_level("error")
		if not cam.start():
			print("mode %s: start failed: %s" % [m, cam.get_last_error()]); continue
		var t0 := Time.get_ticks_msec()
		var last := -1
		var count := 0
		while Time.get_ticks_msec() - t0 < 4000:
			await process_frame
			var fid: int = cam.get_color_frame_id()
			if fid != last:
				last = fid; count += 1
		print("mode %s: color frames %d in 4 s, framesets %d, size %dx%d" % [m, count, cam.get_frameset_count(), cam.get_color_width(), cam.get_color_height()])
		cam.stop()
		await create_timer(1.0).timeout
	quit()
