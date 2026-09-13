shader_type canvas_item;
render_mode blend_add;

// Elemental aura rising from a body mask. Draw this on a quad larger than the
// body; `mask_rect_min/size` say where the body mask sits inside the quad's UV.
uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform vec4 color_core : source_color = vec4(1.0, 0.95, 0.55, 1.0);
uniform vec4 color_mid : source_color = vec4(1.0, 0.45, 0.08, 1.0);
uniform vec4 color_edge : source_color = vec4(0.75, 0.08, 0.02, 1.0);
uniform float rise = 1.0;          // +1 tongues rise (fire), -1 they fall (water)
uniform float swirl = 0.0;         // >0 rotates the tongue direction over time (water vortex)
uniform float spread = 0.35;       // reach beyond the body, in mask UV units
uniform float speed = 0.9;
uniform float intensity = 1.0;
uniform vec2 mask_rect_min = vec2(0.3, 0.2);
uniform vec2 mask_rect_size = vec2(0.4, 0.6);
uniform float flip_x = 0.0;        // 1 when the body sprite is drawn mirrored

float body_at(vec2 p) {
	float inside = step(0.0, p.x) * step(p.x, 1.0) * step(0.0, p.y) * step(p.y, 1.0);
	return texture(mask_tex, clamp(p, vec2(0.0), vec2(1.0))).a * inside;
}

void fragment() {
	vec2 muv = (UV - mask_rect_min) / mask_rect_size;
	if (flip_x > 0.5) {
		muv.x = 1.0 - muv.x;
	}
	float t = TIME * speed;
	float n1 = texture(noise_tex, muv * vec2(1.6, 0.9) + vec2(0.0, -t * 0.35 * rise)).r;
	float n2 = texture(noise_tex, muv * vec2(3.2, 1.8) + vec2(0.37, -t * 0.7 * rise)).r;
	float n = n1 * 0.6 + n2 * 0.4;

	// Tongues: look for the body "below" the fragment along the rise direction,
	// warped by noise so the tongues flicker and split.
	float tongues = 0.0;
	for (int i = 0; i < 7; i++) {
		float f = float(i) / 6.0;
		vec2 warp = (vec2(n1, n2) - 0.5) * spread * (0.25 + f * 0.9);
		vec2 dir = vec2(0.0, rise * f * spread * 2.2);
		if (swirl > 0.0) {
			float ang = swirl * (t * 0.9 + f * 2.5 + (muv.y - 0.5) * 3.0);
			dir = vec2(dir.x * cos(ang) - dir.y * sin(ang), dir.x * sin(ang) + dir.y * cos(ang));
		}
		vec2 p = muv + dir + warp;
		tongues = max(tongues, body_at(p) * (1.0 - f * 0.85));
	}
	// Soft halo all around the body.
	float halo = 0.0;
	for (int k = 0; k < 8; k++) {
		float a = float(k) * 0.7854;
		vec2 o = vec2(cos(a), sin(a)) * spread * (0.35 + 0.35 * n);
		halo = max(halo, body_at(muv + o));
	}
	float v = clamp(tongues * (0.55 + 0.9 * n) + halo * 0.45, 0.0, 1.0) * intensity;
	float flame = smoothstep(0.12, 0.7, v - (1.0 - n) * 0.22);
	vec3 col = mix(color_edge.rgb, color_mid.rgb, smoothstep(0.0, 0.55, flame));
	col = mix(col, color_core.rgb, smoothstep(0.6, 1.0, flame));
	COLOR = vec4(col * flame, flame) * COLOR;
}
