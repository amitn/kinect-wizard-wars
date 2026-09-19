extends SceneTree
## Builds the app icon from the game's own orbs: fire meeting water on a dark tile.
##   godot --headless --path game --script ../tools/make_icon.gd
## Writes game/icon.png (512 px). Godot turns it into the window icon and, with
## rcedit configured (CI does that), into the .exe icon as well.

const SIZE := 512


func _init() -> void:
	var icon := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var fire := _load("res://art/fire_orb.png", 330)
	var water := _load("res://art/water_orb.png", 330)
	var radius := SIZE * 0.2
	for y in SIZE:
		for x in SIZE:
			var p := Vector2(x + 0.5, y + 0.5)
			var inside := _rounded(p, radius)
			if inside <= 0.0:
				continue
			# Warm bottom-left, cold top-right, split along the diagonal.
			var t := clampf(((p.x - p.y) / SIZE + 1.0) * 0.5, 0.0, 1.0)
			var side := smoothstep(0.42, 0.58, t)
			var base := Color(0.20, 0.04, 0.07).lerp(Color(0.03, 0.07, 0.22), side)
			var vignette := 1.0 - 0.55 * p.distance_to(Vector2(SIZE, SIZE) * 0.5) / (SIZE * 0.7)
			var c := Color(base.r * vignette, base.g * vignette, base.b * vignette, 1.0)
			# The orbs are drawn on black: add them, so they glow.
			c = _add(c, fire, p - Vector2(28, 160))
			c = _add(c, water, p - Vector2(156, 24))
			# A thin arcane rim.
			var rim := clampf(1.0 - absf(inside - 7.0) / 3.5, 0.0, 1.0)
			c = c.lerp(Color(0.72, 0.55, 1.0), rim * 0.85)
			c.a = clampf(inside, 0.0, 1.0)
			icon.set_pixel(x, y, c)
	var err := icon.save_png("res://icon.png")
	print("icon.png: %s" % error_string(err))
	quit(0 if err == OK else 1)


func _load(path: String, size: int) -> Image:
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return image


func _add(c: Color, orb: Image, at: Vector2) -> Color:
	if at.x < 0 or at.y < 0 or at.x >= orb.get_width() or at.y >= orb.get_height():
		return c
	var o := orb.get_pixel(int(at.x), int(at.y))
	return Color(minf(1.0, c.r + o.r), minf(1.0, c.g + o.g), minf(1.0, c.b + o.b), 1.0)


## Distance in pixels inside a rounded square (<= 0 outside).
func _rounded(p: Vector2, radius: float) -> float:
	var half := Vector2(SIZE, SIZE) * 0.5
	var q := (p - half).abs() - (half - Vector2(radius, radius))
	var outside := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0)
	return radius - outside
