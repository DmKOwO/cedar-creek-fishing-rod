shader_type spatial;
render_mode unshaded, cull_disabled;

varying vec3 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float stripe = sin(world.z * 15.0 + sin(world.x * 2.1 + TIME) * 1.4 - TIME * 1.7);
	float breakup = sin(world.x * 4.5 + world.z * 2.7) * sin(world.x * 1.2 - TIME * 0.7);
	float glint = smoothstep(0.64, 1.36, stripe * 0.78 + breakup * 0.58);
	vec3 deep = vec3(0.105, 0.31, 0.46);
	vec3 shallow = vec3(0.20, 0.48, 0.54);
	float shore = smoothstep(0.0, 1.0, abs(world.x + 1.4) / 15.0);
	ALBEDO = mix(deep, shallow, shore) + glint * vec3(0.10, 0.18, 0.20);
}
