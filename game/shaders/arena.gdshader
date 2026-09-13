shader_type canvas_item;

// Cyber-arcane arena: dark sky with a faint hex grid and drifting motes, a neon
// perspective floor scrolling toward the viewer, warm light on the fire side and
// cold light on the water side.
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform float horizon = 0.87;      // floor starts here (GROUND_Y / 1080)
uniform vec4 fire_col : source_color = vec4(1.0, 0.45, 0.1, 1.0);
uniform vec4 water_col : source_color = vec4(0.3, 0.65, 1.0, 1.0);
uniform vec4 sky_top : source_color = vec4(0.03, 0.02, 0.07, 1.0);
uniform vec4 sky_bottom : source_color = vec4(0.10, 0.05, 0.18, 1.0);
uniform float fire_energy = 0.0;   // 0..1, pulses when the fire wizard casts
uniform float water_energy = 0.0;
uniform sampler2D backdrop_tex : filter_linear, repeat_disable;
uniform float use_backdrop = 0.0;  // 1 = paint the generated backdrop under the effects

float hex_grid(vec2 p) {
	// Distance to the nearest hex edge in a pointy-top hex lattice.
	vec2 q = vec2(p.x * 1.1547, p.y + p.x * 0.5774);
	vec2 pi = floor(q);
	vec2 pf = fract(q);
	float v = mod(pi.x + pi.y, 3.0);
	float ca = step(1.0, v);
	float cb = step(2.0, v);
	vec2 ma = step(pf.xy, pf.yx);
	float e = dot(ma, 1.0 - pf.yx + ca * (pf.x + pf.y - 1.0) + cb * (pf.yx - 2.0 * pf.xy));
	return e;
}

void fragment() {
	vec2 uv = UV;
	float side = smoothstep(0.35, 0.65, uv.x);     // 0 = fire side, 1 = water side
	vec3 tint = mix(fire_col.rgb, water_col.rgb, side);
	vec3 col;
	if (uv.y < horizon) {
		// Sky.
		col = mix(sky_top.rgb, sky_bottom.rgb, uv.y / horizon);
		float hx = hex_grid(vec2(uv.x * 1.777, uv.y) * 14.0);
		float grid = 1.0 - smoothstep(0.0, 0.06, hx);
		float gpulse = 0.35 + 0.35 * texture(noise_tex, uv * 1.5 + vec2(TIME * 0.02, 0.0)).r;
		col += tint * grid * 0.06 * gpulse;
		// Drifting motes.
		float m = texture(noise_tex, uv * vec2(6.0, 3.0) + vec2(0.0, -TIME * 0.03)).r;
		float motes = smoothstep(0.78, 0.9, m) * (0.4 + 0.6 * sin(TIME * 2.0 + m * 40.0));
		col += tint * motes * 0.35;
		// Glow near the horizon and from the side lights.
		float hglow = pow(1.0 - (horizon - uv.y) / horizon, 6.0);
		col += tint * hglow * 0.35;
		float edge_light = pow(1.0 - min(uv.x, 1.0 - uv.x) * 2.0, 5.0);
		col += tint * edge_light * 0.25 * (0.7 + 0.3 * sin(TIME * 1.3));
		// Tall light beams on the far left and right.
		float beam = smoothstep(0.012, 0.0, abs(uv.x - 0.045)) + smoothstep(0.012, 0.0, abs(uv.x - 0.955));
		col += tint * beam * 0.35 * (0.6 + 0.4 * sin(TIME * 3.0 + uv.y * 20.0));
	} else {
		// Floor in perspective.
		float d = (uv.y - horizon) / (1.0 - horizon);          // 0 at horizon, 1 at bottom
		float depth = 1.0 / (d * 5.0 + 0.08);
		float fx = (uv.x - 0.5) * depth * 6.0;
		float fz = depth * 3.0 - TIME * 0.6;
		float lx = 1.0 - smoothstep(0.0, 0.08 * depth, abs(fract(fx) - 0.5) * 2.0 - 0.9 + 0.9);
		float lz = 1.0 - smoothstep(0.0, 0.08 * depth, abs(fract(fz) - 0.5) * 2.0 - 0.9 + 0.9);
		float line = max(lx, lz);
		col = mix(sky_bottom.rgb * 1.1, vec3(0.05, 0.05, 0.10), d);
		float fade = 1.0 - smoothstep(0.0, 0.35, d) * 0.4;
		col += tint * line * 0.75 * fade;
		// Tile sheen.
		float sheen = texture(noise_tex, vec2(fx * 0.15, fz * 0.15)).r;
		col += tint * sheen * 0.08;
		// Reflection of the side glows and a horizon line.
		col += tint * pow(1.0 - d, 3.0) * 0.45;
		col += tint * smoothstep(0.02, 0.0, d) * 0.8;
	}
	if (use_backdrop > 0.5) {
		vec3 art = texture(backdrop_tex, uv).rgb;
		// Keep the animated motes, beams and energy; replace the flat paint with the art.
		float motes2 = smoothstep(0.8, 0.92, texture(noise_tex, uv * vec2(6.0, 3.0) + vec2(0.0, -TIME * 0.03)).r);
		col = art * 0.92 + tint * motes2 * 0.3 * (0.4 + 0.6 * sin(TIME * 2.0 + uv.x * 40.0));
	}
	// Cast energy: a soft flare on the caster's half.
	col += fire_col.rgb * fire_energy * (1.0 - side) * 0.25;
	col += water_col.rgb * water_energy * side * 0.25;
	COLOR = vec4(col, 1.0);
}
