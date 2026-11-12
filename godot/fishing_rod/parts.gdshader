shader_type spatial;

void fragment() {
	ALBEDO = COLOR.rgb;
	METALLIC = COLOR.a * 0.52;
	ROUGHNESS = mix(0.77, 0.32, clamp(COLOR.a * 1.8, 0.0, 1.0));
}
