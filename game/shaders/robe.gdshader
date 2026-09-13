shader_type canvas_item;

// Paints a body mask (LA8 silhouette, alpha = body) as a hooded, caped wizard.
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform vec4 robe : source_color = vec4(0.62, 0.14, 0.08, 1.0);
uniform vec4 robe_dark : source_color = vec4(0.35, 0.07, 0.05, 1.0);
uniform vec4 cape : source_color = vec4(0.85, 0.28, 0.10, 1.0);
uniform vec4 hood : source_color = vec4(0.45, 0.10, 0.06, 1.0);
uniform vec4 trim : source_color = vec4(0.95, 0.75, 0.35, 1.0);
uniform vec4 rim : source_color = vec4(1.0, 0.85, 0.45, 1.0);
uniform vec4 veins : source_color = vec4(1.0, 0.45, 0.1, 1.0);
uniform float vein_strength = 1.0;   // glowing cracks running through the cloth
uniform float hood_end = 0.14;     // fraction of the mask height, top to bottom
uniform float cape_end = 0.34;
uniform float belt_y = 0.55;

void fragment() {
	vec4 m = texture(TEXTURE, UV);
	float a = m.a;
	vec2 px = TEXTURE_PIXEL_SIZE;

	// Rim: how much of the 2-pixel neighbourhood is outside the body.
	float outside = 0.0;
	outside = max(outside, 1.0 - texture(TEXTURE, UV + vec2(px.x, 0.0)).a);
	outside = max(outside, 1.0 - texture(TEXTURE, UV - vec2(px.x, 0.0)).a);
	outside = max(outside, 1.0 - texture(TEXTURE, UV + vec2(0.0, px.y)).a);
	outside = max(outside, 1.0 - texture(TEXTURE, UV - vec2(0.0, px.y)).a);
	float outside2 = 0.0;
	outside2 = max(outside2, 1.0 - texture(TEXTURE, UV + vec2(2.0 * px.x, 0.0)).a);
	outside2 = max(outside2, 1.0 - texture(TEXTURE, UV - vec2(2.0 * px.x, 0.0)).a);
	outside2 = max(outside2, 1.0 - texture(TEXTURE, UV + vec2(0.0, 2.0 * px.y)).a);
	outside2 = max(outside2, 1.0 - texture(TEXTURE, UV - vec2(0.0, 2.0 * px.y)).a);
	float edge = clamp(outside * 0.9 + outside2 * 0.45, 0.0, 1.0);

	// Cloth folds: vertical noise stripes, slightly waving.
	float fold = texture(noise_tex, vec2(UV.x * 5.0 + sin(UV.y * 9.0) * 0.08, UV.y * 1.3 + TIME * 0.03)).r;
	vec3 col = mix(robe_dark.rgb, robe.rgb, smoothstep(0.3, 0.7, fold));

	// Hood, cape and belt bands by height.
	float hood_w = 1.0 - smoothstep(hood_end - 0.02, hood_end + 0.02, UV.y);
	float cape_w = smoothstep(hood_end - 0.01, hood_end + 0.01, UV.y) * (1.0 - smoothstep(cape_end - 0.03, cape_end + 0.03, UV.y));
	float belt_w = smoothstep(belt_y - 0.025, belt_y - 0.01, UV.y) * (1.0 - smoothstep(belt_y + 0.01, belt_y + 0.025, UV.y));
	float trim_w = smoothstep(cape_end - 0.005, cape_end + 0.005, UV.y) * (1.0 - smoothstep(cape_end + 0.015, cape_end + 0.025, UV.y));
	col = mix(col, hood.rgb, hood_w);
	col = mix(col, cape.rgb * (0.85 + 0.3 * fold), cape_w);
	col = mix(col, trim.rgb, max(belt_w, trim_w) * 0.9);

	// Shading: darker toward the hem and toward the sides of the body.
	col *= mix(1.0, 0.55, smoothstep(0.7, 1.0, UV.y));
	col *= 0.8 + 0.4 * (1.0 - abs(UV.x - 0.5) * 2.0);

	// Ember veins: thin ridges of a second noise field, pulsing slowly, denser near the hem.
	float crack_field = texture(noise_tex, vec2(UV.x * 3.5, UV.y * 2.2) + vec2(0.61, 0.17)).r;
	float ridge = 1.0 - smoothstep(0.0, 0.035, abs(crack_field - 0.5));
	float pulse = 0.7 + 0.3 * sin(TIME * 2.0 + UV.y * 8.0 + crack_field * 6.0);
	float vein = ridge * pulse * vein_strength * (0.55 + 0.45 * UV.y);
	col = mix(col, veins.rgb * 1.4, clamp(vein, 0.0, 1.0));

	col = mix(col, rim.rgb, edge * 0.85);
	COLOR = vec4(col, a) * COLOR;
}
