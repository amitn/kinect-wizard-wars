extends SceneTree
## Runs the real RtmPoseProcessor against the live camera for a few seconds and
## prints every decision it makes. Run with `-- --tracklog` for the processor's own log.
## Note: the BodyTracker autoload opens its own camera in --script runs too, and two
## pipelines starve each other; read rates from the game (--tracklog) instead.

func _init() -> void:
	var cam = ClassDB.instantiate("OrbbecCamera")
	get_root().add_child(cam)
	if not cam.start():
		print("no camera: ", cam.get_last_error()); quit(); return
	var proc := RtmPoseProcessor.new()
	if not proc.setup(cam):
		print("setup failed: ", proc.last_error); quit(); return
	proc.poses_ready.connect(func(people, _ts):
		var s := ""
		for p in people:
			s += " root=(%.2f,%.2f,%.2f) box=%s |" % [p["root"].x, p["root"].y, p["root"].z, p["box"]]
		print("people=%d%s" % [people.size(), s]))
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while Time.get_ticks_msec() - t0 < 8000:
		await process_frame
		proc.poll()
		frames += 1
	print("frames polled ", frames, "  poses/s ", proc.poses_per_second, "  last boxes ", proc.last_boxes)
	cam.stop()
	quit()
