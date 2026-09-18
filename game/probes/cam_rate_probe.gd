extends SceneTree
## Measures how fast color frames actually arrive from the extension.
func _init() -> void:
	var cam = ClassDB.instantiate("OrbbecCamera")
	get_root().add_child(cam)
	if not cam.start():
		print("no camera: ", cam.get_last_error()); quit(); return
	var t0 := Time.get_ticks_msec()
	var last := -1
	var count := 0
	var stamps: Array = []
	while Time.get_ticks_msec() - t0 < 6000:
		await process_frame
		var fid: int = cam.get_color_frame_id()
		if fid != last:
			last = fid
			count += 1
			stamps.append([Time.get_ticks_msec() - t0, cam.get_timestamp()])
	print("color frames in 6 s: ", count, "  (", count / 6.0, " fps)   size ", cam.get_color_width(), "x", cam.get_color_height())
	print("first stamps (wall ms, cam ms): ", stamps.slice(0, 8))
	cam.stop()
	quit()
