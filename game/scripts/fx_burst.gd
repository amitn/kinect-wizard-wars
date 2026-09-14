class_name FXBurst
extends Sprite2D
## A short additive frame animation (fire explosion, water splash) at a point.

const FPS := 14.0
static var _frames_cache: Dictionary = {}

var _frames: Array = []
var _age := 0.0


static func frames_for(element: String) -> Array:
	if _frames_cache.has(element):
		return _frames_cache[element]
	var frames: Array = []
	for i in 8:
		var path := "res://art/%s_impact_%d.png" % [element, i]
		if not ResourceLoader.exists(path):
			break
		frames.append(load(path))
	_frames_cache[element] = frames
	return frames


## Returns null when no impact art exists for the element.
static func spawn(parent: Node, at: Vector2, element: String, size: float = 420.0, tint: Color = Color.WHITE) -> FXBurst:
	var frames := frames_for(element)
	if frames.is_empty():
		return null
	var b := FXBurst.new()
	b._frames = frames
	b.texture = frames[0]
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	b.material = mat
	b.position = at
	b.rotation = randf_range(-0.3, 0.3)
	b.modulate = tint
	var tex_h: float = maxf(1.0, (frames[0] as Texture2D).get_height())
	b.scale = Vector2.ONE * (size / tex_h)
	parent.add_child(b)
	return b


func _process(delta: float) -> void:
	_age += delta
	var idx := int(_age * FPS)
	if idx >= _frames.size():
		queue_free()
		return
	texture = _frames[idx]
	var f := _age * FPS / _frames.size()
	modulate.a = 1.0 - f * f
