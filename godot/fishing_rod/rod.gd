extends Node3D
## First-person baitcasting rod. Call step() once per frame with the fishing game's state.

const ROD_LENGTH := 1.96
const JOINT := 0.42
const BASE_RATE := 0.38
const TIP_RATE := (1.0 - JOINT * BASE_RATE) / (1.0 - JOINT)
const GUIDES := [0.14, 0.32, 0.49, 0.63, 0.75, 0.85, 0.93, 1.0]
const PACK_FULL_RADIUS := 0.0565
const PACK_CORE_RADIUS := 0.041
const LINE_SIDES := 5
const LINE_SPANS := 18

@export_range(1.0, 12.0, 0.1) var gear_ratio := 6.3
@export_range(0.1, 4.0, 0.05) var max_crank_turns_per_second := 1.65
@export_range(0.01, 2.0, 0.01) var max_bend_radians := 1.83
@export_range(0.0002, 0.02, 0.0001) var line_radius := 0.00155
@export_range(4.0, 150.0, 1.0) var spool_capacity_m := 35.0
@export_range(0.0, 150.0, 0.1) var initial_deployed_m := 8.0
@export_range(0.0, 0.5, 0.01) var lift_pitch_radians := 0.20
@export_range(0.0, 0.35, 0.01) var lift_pullback_m := 0.10
@export_range(0.0, 0.35, 0.01) var lift_height_m := 0.21
@export_range(0.0, 0.35, 0.01) var jerk_reach_m := 0.18
@export var show_hands := true
@export var show_float := true

@onready var rig: Node3D = $Model/Rig
@onready var blank: MeshInstance3D = $Model/Rig/Blank
@onready var crank: Node3D = $Model/Rig/Crank
@onready var knob: Node3D = $Model/Rig/Crank/Knob
@onready var contact: Node3D = $Model/Rig/Crank/Knob/HandContact
@onready var spool: Node3D = $Model/Rig/Spool
@onready var pack: Node3D = $Model/Rig/Spool/LinePack
@onready var carriage: Node3D = $Model/Rig/LevelWind
@onready var carriage_eye: Node3D = $Model/Rig/LevelWind/LineEye
@onready var left_hand: Node3D = $Model/Rig/Hands/LeftHand
@onready var right_hand: Node3D = $Model/Rig/Hands/RightHand
@onready var right_sleeve: Node3D = $Model/Rig/Hands/RightHand/RightHandSleeve
@onready var left_sleeve: Node3D = $Model/Rig/Hands/LeftHand/LeftHandSleeve
@onready var float_model: Node3D = $Model/Rig/Float
@onready var float_eye: Node3D = $Model/Rig/Float/FloatEye
@onready var line: MeshInstance3D = $Line

var deployed_m := 0.0
var _rig_rest: Transform3D
var _grip_in_rig: Vector3
var _right_elbow: Vector3
var _left_elbow: Vector3
var _float_basis_in_rod: Basis
var _lift := 0.0
var _jerk := 0.0
var _guides: Array[Node3D] = []
var _eyes: Array[Node3D] = []
var _blank_material: ShaderMaterial
var _line_mesh := ImmediateMesh.new()
var _line_material := StandardMaterial3D.new()
var _spool_phase := 0.0
var _traverse_phase := 0.14
var _crank_phase := 0.0
var _crank_speed := 0.0
var _bend := 0.0
var _bend_direction := Vector2.DOWN * -1.0
var _clock := 0.0
var _points := PackedVector3Array()
var _line_rings := PackedVector3Array()

func _ready() -> void:
	deployed_m = clampf(initial_deployed_m, 0.0, spool_capacity_m)
	_rig_rest = rig.transform
	_grip_in_rig = rig.to_local(right_hand.global_position)
	_right_elbow = to_local(right_sleeve.to_global(Vector3(0.0, 0.0, 0.34)))
	_left_elbow = to_local(rig.to_global(Vector3(-0.37, -0.13, 0.60)))
	_float_basis_in_rod = global_basis.inverse() * float_model.global_basis
	for index in GUIDES.size():
		var guide := rig.get_node("Guide%02d" % index) as Node3D
		_guides.append(guide)
		_eyes.append(guide.get_node("Eye%02d" % index) as Node3D)
	var parts_material := ShaderMaterial.new()
	parts_material.shader = preload("parts.gdshader")
	for part in rig.find_children("*", "MeshInstance3D", true, false):
		part.material_override = parts_material
	_blank_material = ShaderMaterial.new()
	_blank_material.shader = preload("blank.gdshader")
	blank.material_override = _blank_material
	blank.extra_cull_margin = ROD_LENGTH
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.albedo_color = Color("#ffdd9d")
	_line_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	line.mesh = _line_mesh
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_points.resize(2 + GUIDES.size() + LINE_SPANS)
	_line_rings.resize(_points.size() * LINE_SIDES)
	step(0.0, to_global(Vector3(0.0, -0.55, -4.0)), 0.0, 0.0)

## tension: 0–1. retrieve: 0–1. payout_mps: outgoing line under drag, in metres/second.
## lift: 0–1 to pull the grip up and back. fish_jerk: 0–1 to pull both hands forward.
## endpoint_world is the line attachment point, e.g. a bobber socket or fish mouth.
## Returns net metres collected this frame. Negative means the fish took line.
func step(delta: float, endpoint_world: Vector3, tension: float, retrieve: float,
		payout_mps: float = 0.0, lift: float = 0.0, fish_jerk: float = 0.0) -> float:
	var dt := maxf(0.0, delta)
	var load_amount := clampf(tension, 0.0, 1.0)
	_clock += dt
	_pose_hands(dt, endpoint_world, lift, fish_jerk)
	var drive := clampf(retrieve, 0.0, 1.0) * max_crank_turns_per_second
	drive *= lerpf(1.0, 0.53, load_amount)
	_crank_speed = move_toward(_crank_speed, drive, dt * (9.0 if drive > _crank_speed else 16.0))

	var full_fraction := 1.0 - clampf(deployed_m / spool_capacity_m, 0.0, 1.0)
	var radius := sqrt(lerpf(PACK_CORE_RADIUS * PACK_CORE_RADIUS,
		PACK_FULL_RADIUS * PACK_FULL_RADIUS, full_fraction))
	var circumference := TAU * radius
	var crank_turns := minf(_crank_speed * dt,
		(deployed_m + maxf(payout_mps, 0.0) * dt) / (gear_ratio * circumference))
	var collected := clampf(crank_turns * gear_ratio * circumference -
		maxf(payout_mps, 0.0) * dt, deployed_m - spool_capacity_m, deployed_m)
	deployed_m -= collected

	_crank_phase = fposmod(_crank_phase + crank_turns * TAU, TAU)
	var spool_turns := collected / circumference
	_spool_phase = fposmod(_spool_phase + TAU * spool_turns, TAU)
	# The guide runs on its own slow gearing, driven by the same spool.
	_traverse_phase = fposmod(_traverse_phase + spool_turns / 22.0, 2.0)
	crank.rotation.x = _crank_phase
	knob.rotation.x = -_crank_phase
	spool.rotation.x = _spool_phase
	pack.scale = Vector3(1.0, radius / PACK_FULL_RADIUS, radius / PACK_FULL_RADIUS)
	carriage.position.x = (1.0 - absf(_traverse_phase - 1.0) - 0.5) * 0.105
	left_hand.position = left_hand.get_parent_node_3d().to_local(contact.global_position)
	_aim_sleeve(left_sleeve, _left_elbow)
	_aim_sleeve(right_sleeve, _right_elbow)
	rig.get_node("Hands").visible = show_hands
	float_model.visible = show_float
	float_model.global_basis = global_basis * _float_basis_in_rod
	float_model.global_position += endpoint_world - float_eye.global_position

	var local_endpoint := rig.to_local(endpoint_world)
	var pull := Vector2(local_endpoint.x, local_endpoint.y)
	if pull.length_squared() > 0.0001:
		var bearing := pull.normalized()
		_bend_direction = _bend_direction.rotated(
			_bend_direction.angle_to(bearing) * (1.0 - exp(-12.0 * dt)))
	_bend = lerpf(_bend, max_bend_radians * pow(load_amount, 0.86),
		1.0 - exp(-10.0 * dt))
	_blank_material.set_shader_parameter("bend_direction", _bend_direction)
	_blank_material.set_shader_parameter("bend_angle", _bend)

	var axis := Vector3(_bend_direction.y, -_bend_direction.x, 0.0)
	for index in GUIDES.size():
		var t: float = GUIDES[index]
		var first := minf(t, JOINT)
		var last := maxf(0.0, t - JOINT)
		var base_angle := first * _bend * BASE_RATE
		var center := ROD_LENGTH * (_arc(first, 0.0, _bend * BASE_RATE) +
			_arc(last, base_angle, _bend * TIP_RATE))
		_guides[index].transform = Transform3D(
			Basis(axis, base_angle + last * _bend * TIP_RATE),
			Vector3(_bend_direction.x * center.x, _bend_direction.y * center.x, -center.y))

	line.global_transform = rig.global_transform
	_draw_line(radius, local_endpoint, load_amount)
	return collected

func _pose_hands(dt: float, endpoint_world: Vector3, lift: float, fish_jerk: float) -> void:
	var lift_target := clampf(lift, 0.0, 1.0)
	_lift = lerpf(_lift, lift_target, 1.0 - exp(-dt * (5.5 if lift_target > _lift else 7.0)))
	var jerk_target := clampf(fish_jerk, 0.0, 1.0)
	_jerk = lerpf(_jerk, jerk_target, 1.0 - exp(-dt * (23.0 if jerk_target > _jerk else 8.0)))

	# Move the grip and the reel together. Keep the forearm anchors in player space.
	var resting_target := _rig_rest.affine_inverse() * rig.get_parent_node_3d().to_local(endpoint_world)
	var direction := resting_target.normalized()
	var offset := Vector3(0.025, lift_height_m, lift_pullback_m) * _lift
	offset += direction * (jerk_reach_m * _jerk)
	var pitch := lift_pitch_radians * _lift - 0.21 * _jerk
	var yaw := -direction.x * 0.11 * _jerk
	var roll := -0.11 * _lift + direction.x * 0.10 * _jerk
	var rotation_basis := Basis.from_euler(Vector3(pitch, yaw, roll))
	# The right palm is the pivot. Pitch the rod around its grip instead of the blank.
	offset += _grip_in_rig - rotation_basis * _grip_in_rig
	rig.transform = _rig_rest * Transform3D(rotation_basis, offset)

func _aim_sleeve(sleeve: Node3D, elbow: Vector3) -> void:
	var parent := sleeve.get_parent_node_3d()
	var reach := parent.to_local(to_global(elbow)) - sleeve.position
	if reach.length_squared() < 0.00001:
		return
	var length_scale := clampf(reach.length() / 0.29, 0.85, 1.65)
	sleeve.basis = Basis(Quaternion(Vector3.BACK, reach.normalized())) * Basis.from_scale(
		Vector3(1.0, 1.0, length_scale))

func _arc(span: float, start: float, rate: float) -> Vector2:
	if absf(rate) < 0.0001:
		return Vector2(sin(start), cos(start)) * span
	var end := start + span * rate
	return Vector2(cos(start) - cos(end), sin(end) - sin(start)) / rate

func _draw_line(radius: float, endpoint: Vector3, load_amount: float) -> void:
	var exit_y := rig.to_local(carriage_eye.global_position).y - spool.position.y
	var exit_z := rig.to_local(carriage_eye.global_position).z - spool.position.z
	var toward_eye := Vector2(exit_y, exit_z)
	var tangent_angle := toward_eye.angle() + acos(clampf(radius / toward_eye.length(), 0.0, 1.0))
	_points[0] = Vector3(carriage.position.x, spool.position.y + cos(tangent_angle) * radius,
		spool.position.z + sin(tangent_angle) * radius)
	_points[1] = rig.to_local(carriage_eye.global_position)
	for index in _eyes.size():
		_points[index + 2] = rig.to_local(_eyes[index].global_position)

	var tip := _points[1 + GUIDES.size()]
	var span := endpoint - tip
	var sag := minf(span.length() * 0.17, 0.82) * pow(1.0 - load_amount, 2.0)
	var gravity := rig.global_basis.inverse() * Vector3.DOWN
	var flutter := rig.global_basis.inverse() * Vector3.RIGHT
	for index in range(1, LINE_SPANS + 1):
		var u := float(index) / LINE_SPANS
		var envelope := 4.0 * u * (1.0 - u)
		_points[1 + GUIDES.size() + index] = tip.lerp(endpoint, u) + envelope * (
			gravity * sag + flutter * (sag * 0.045 * sin(_clock * 4.0 - u * 7.0)))

	for index in _points.size():
		var tangent := _points[mini(index + 1, _points.size() - 1)] - _points[maxi(index - 1, 0)]
		if tangent.length_squared() < 0.0000001:
			tangent = Vector3.FORWARD
		tangent = tangent.normalized()
		var normal := tangent.cross(Vector3.RIGHT)
		if normal.length_squared() < 0.01:
			normal = tangent.cross(Vector3.UP)
		normal = normal.normalized()
		var binormal := tangent.cross(normal)
		var radius_here := line_radius
		if index > 1 + GUIDES.size():
			radius_here *= 1.45
		for side in LINE_SIDES:
			var theta := TAU * side / LINE_SIDES
			_line_rings[index * LINE_SIDES + side] = _points[index] + radius_here * (
				cos(theta) * normal + sin(theta) * binormal)

	_line_mesh.clear_surfaces()
	_line_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _line_material)
	for index in _points.size() - 1:
		for side in LINE_SIDES:
			var next := (side + 1) % LINE_SIDES
			var a := index * LINE_SIDES
			var b := a + LINE_SIDES
			_line_mesh.surface_add_vertex(_line_rings[a + side])
			_line_mesh.surface_add_vertex(_line_rings[b + side])
			_line_mesh.surface_add_vertex(_line_rings[a + next])
			_line_mesh.surface_add_vertex(_line_rings[a + next])
			_line_mesh.surface_add_vertex(_line_rings[b + side])
			_line_mesh.surface_add_vertex(_line_rings[b + next])
	_line_mesh.surface_end()
