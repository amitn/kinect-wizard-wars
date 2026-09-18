extends SceneTree

func _init():
	print("RtmPose class: ", ClassDB.class_exists("RtmPose"))
	if not ClassDB.class_exists("RtmPose"):
		quit(); return
	var pose = ClassDB.instantiate("RtmPose")
	var f = FileAccess.open("res://models/rtmpose-t.onnx", FileAccess.READ)
	if f == null:
		print("model missing"); quit(); return
	var bytes := f.get_buffer(f.get_length())
	var t0 := Time.get_ticks_msec()
	var ok: bool = pose.initialize(bytes, 4)
	print("initialize: ", ok, "  (", Time.get_ticks_msec() - t0, " ms)  err=", pose.get_last_error())
	if not ok:
		quit(); return
	print("input ", pose.get_input_size(), "  keypoints ", pose.get_keypoint_count())

	var img := Image.create(1280, 720, false, Image.FORMAT_RGB8)
	img.fill(Color(0.25, 0.3, 0.38))
	img.fill_rect(Rect2i(560, 200, 160, 500), Color(0.8, 0.7, 0.62))
	img.fill_rect(Rect2i(590, 150, 90, 90), Color(0.85, 0.75, 0.68))
	var box := Rect2(540, 140, 210, 570)

	for i in 3:
		pose.infer(img, box)
	var times: Array[float] = []
	for i in 12:
		var s := Time.get_ticks_usec()
		var kps = pose.infer(img, box)
		times.append((Time.get_ticks_usec() - s) / 1000.0)
		if i == 0:
			print("keypoints returned: ", kps.size(), "   first three: ", kps.slice(0, 3))
	times.sort()
	print("infer ms   median %.1f   min %.1f   max %.1f" % [times[times.size() / 2], times[0], times[-1]])
	print("preprocess ms %.2f of that" % pose.get_preprocess_ms())
	quit()
