extends SceneTree
## Keys a flat magenta background to alpha and splits a one-row pose sheet into
## separate PNGs by scanning for empty columns.
##
##   godot --headless -s tools/split_sheet.gd -- <sheet.png> <out_dir> <prefix> [pose names...]
##   godot --headless -s tools/split_sheet.gd -- images/fire_wizard_sheet.png game/art fire idle cast shield hit
##
## With no pose names the pieces are saved as <prefix>_0.png, <prefix>_1.png ...

const KEY := Color(1.0, 0.0, 1.0)
const KEY_INNER := 0.22    # colour distance below which a pixel is pure background
const KEY_OUTER := 0.55    # ...and above which it is pure foreground
const MIN_GAP := 6         # empty columns that separate two poses
const MIN_WIDTH_FRAC := 0.07


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("usage: -- <sheet.png> <out_dir> <prefix> [pose names...]")
		quit(2)
		return
	var src: String = args[0]
	var out_dir: String = args[1]
	var prefix: String = args[2]
	var names: Array = args.slice(3)

	var img := Image.new()
	var err := img.load(src)
	if err != OK:
		push_error("cannot load %s (%d)" % [src, err])
		quit(1)
		return
	img.convert(Image.FORMAT_RGBA8)
	_key_magenta(img)

	var pieces := _split_columns(img)
	print("%s: %dx%d, %d pieces" % [src, img.get_width(), img.get_height(), pieces.size()])
	DirAccess.make_dir_recursive_absolute(out_dir)
	for i in pieces.size():
		var rect: Rect2i = pieces[i]
		var piece := img.get_region(rect)
		var name: String = names[i] if i < names.size() else str(i)
		var path := "%s/%s_%s.png" % [out_dir, prefix, name]
		piece.save_png(path)
		print("  %s  %dx%d at x=%d" % [path, rect.size.x, rect.size.y, rect.position.x])
	quit(0)


func _key_magenta(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var d := Vector3(c.r - KEY.r, c.g - KEY.g, c.b - KEY.b).length()
			var a := clampf((d - KEY_INNER) / (KEY_OUTER - KEY_INNER), 0.0, 1.0)
			if a <= 0.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			elif a < 1.0:
				# Remove the background's contribution from the blended edge pixel.
				var fg := Color(
					clampf((c.r - (1.0 - a) * KEY.r) / a, 0.0, 1.0),
					clampf((c.g - (1.0 - a) * KEY.g) / a, 0.0, 1.0),
					clampf((c.b - (1.0 - a) * KEY.b) / a, 0.0, 1.0), a)
				img.set_pixel(x, y, fg)


func _split_columns(img: Image) -> Array:
	var w := img.get_width()
	var h := img.get_height()
	var occupied := PackedByteArray()
	occupied.resize(w)
	for x in w:
		var any := 0
		for y in h:
			if img.get_pixel(x, y).a > 0.5:
				any = 1
				break
		occupied[x] = any
	# Runs of occupied columns, ignoring gaps shorter than MIN_GAP.
	var runs: Array = []
	var start := -1
	var gap := 0
	for x in w:
		if occupied[x]:
			if start < 0:
				start = x
			gap = 0
		elif start >= 0:
			gap += 1
			if gap >= MIN_GAP:
				runs.append(Vector2i(start, x - gap))
				start = -1
				gap = 0
	if start >= 0:
		runs.append(Vector2i(start, w - 1))
	# Drop slivers (stray embers), then crop each run vertically.
	var pieces: Array = []
	for r in runs:
		if r.y - r.x < w * MIN_WIDTH_FRAC:
			continue
		var top := h
		var bottom := -1
		for y in h:
			for x in range(r.x, r.y + 1):
				if img.get_pixel(x, y).a > 0.5:
					top = mini(top, y)
					bottom = maxi(bottom, y)
					break
		if bottom < 0:
			continue
		pieces.append(Rect2i(r.x, top, r.y - r.x + 1, bottom - top + 1))
	return pieces
