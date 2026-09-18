extends SceneTree
## Live accuracy probe: grabs real frames from the camera, saves one as PNG,
## and runs RTMPose over the depth boxes and the sweep columns with both channel
## orders, printing the scores. Run on the Windows PC with someone in front:
##   Godot_console.exe --headless --path <project> --script res://rtmpose_live_probe.gd

func _init() -> void:
	var cam = ClassDB.instantiate("OrbbecCamera")
	get_root().add_child(cam)
	if not cam.start():
		print("no camera: ", cam.get_last_error()); quit(); return
	var pose = ClassDB.instantiate("RtmPose")
	var f := FileAccess.open("res://models/rtmpose-t.onnx", FileAccess.READ)
	pose.initialize(f.get_buffer(f.get_length()), 3)
	# Let the stream settle.
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		await create_timer(0.1).timeout
	for shot in 3:
		var img: Image = cam.get_color_image()
		if img == null:
			print("no color frame yet"); await create_timer(0.5).timeout; continue
		var path := "user://live_%d.png" % shot
		img.save_png(path)
		print("saved ", ProjectSettings.globalize_path(path), "  ", img.get_size())
		var boxes: Array = cam.get_person_boxes(0.8, 3.6, 0.25)
		print("depth boxes: ", boxes)
		var candidates: Array = boxes.duplicate()
		for i in 4:
			candidates.append(Rect2(i * 256.0, 0.0, 512.0, 720.0))
		candidates.append(Rect2(0, 0, 1280, 720))
		for rgb in [true, false]:
			pose.set_rgb_input(rgb)
			for box in candidates:
				var kps: PackedVector3Array = pose.infer(img, box)
				if kps.is_empty():
					continue
				var mean := 0.0
				var best := 0.0
				for k in kps:
					mean += k.z; best = maxf(best, k.z)
				mean /= kps.size()
				print("  rgb=%s box=%s  mean=%.3f best=%.3f  nose=(%.0f,%.0f) Lwrist=(%.0f,%.0f) Rwrist=(%.0f,%.0f) Lhip=(%.0f,%.0f)" % [
					rgb, box, mean, best, kps[0].x, kps[0].y, kps[9].x, kps[9].y, kps[10].x, kps[10].y, kps[11].x, kps[11].y])
		await create_timer(1.0).timeout
	cam.stop()
	quit()
