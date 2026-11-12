shader_type spatial;

uniform vec2 bend_direction = vec2(0.0, -1.0);
uniform float bend_angle = 0.0;

const float ROD_LENGTH = 1.96;
const float JOINT = 0.42;
const float BASE_RATE = 0.38;
const float TIP_RATE = (1.0 - JOINT * BASE_RATE) / (1.0 - JOINT);

vec2 arc(float span, float start, float rate) {
	if (abs(rate) < 0.0001) {
		return span * vec2(sin(start), cos(start));
	}
	float end = start + span * rate;
	return vec2(cos(start) - cos(end), sin(end) - sin(start)) / rate;
}

void vertex() {
	float t = clamp(-VERTEX.z / ROD_LENGTH, 0.0, 1.0);
	float first = min(t, JOINT);
	float last = max(0.0, t - JOINT);
	float base_angle = bend_angle * BASE_RATE * first;
	float a = base_angle + bend_angle * TIP_RATE * last;
	vec2 curve = ROD_LENGTH * (arc(first, 0.0, bend_angle * BASE_RATE) +
		arc(last, base_angle, bend_angle * TIP_RATE));
	vec2 side = vec2(-bend_direction.y, bend_direction.x);
	float r = dot(VERTEX.xy, bend_direction);
	VERTEX = vec3(side * dot(VERTEX.xy, side) + bend_direction * (curve.x + cos(a) * r),
		-curve.y + sin(a) * r);
	float n = dot(NORMAL.xy, bend_direction);
	NORMAL = vec3(side * dot(NORMAL.xy, side) + bend_direction * (cos(a) * n - sin(a) * NORMAL.z),
		sin(a) * n + cos(a) * NORMAL.z);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.66;
}
