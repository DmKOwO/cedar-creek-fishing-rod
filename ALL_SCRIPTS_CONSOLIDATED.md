# Consolidated Godot Scripts & Shaders — Cedar Creek Fishing Rod

> Единый текстовый файл со всеми исходными кодами проекта для загрузки в чат с ИИ.

## Конфигурация проекта (project.godot)

**Файл:** `godot/project.godot`

```ini
config_version=5

[application]
config/name="Cedar Creek | Fishing Rod"
run/main_scene="res://demo/demo.tscn"
config/features=PackedStringArray("4.3", "GL Compatibility")

[display]
window/size/viewport_width=1280
window/size/viewport_height=720
window/stretch/mode="canvas_items"

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
anti_aliasing/quality/msaa_3d=2

[editor]
movie_writer/fps=30

```

---

## Основной контроллер удочки (rod.gd)

**Файл:** `godot/fishing_rod/rod.gd`

```gdscript
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

```

---

## Скрипт демонстрационной сцены (demo.gd)

**Файл:** `godot/demo/demo.gd`

```gdscript
extends Node3D

@onready var rod = $Rod
@onready var camera: Camera3D = $Camera3D

var _clock := 0.0
var _distance := 5.3
var _auto := true
var _close := false
var _cycle_offset := 0.0
var _lift_load := 0.0
var _bar: ProgressBar
var _status: Label
var _rings: Array[MeshInstance3D] = []

func _ready() -> void:
	_close = "--close" in OS.get_cmdline_user_args()
	_cycle_offset = 2.0 if _close else 0.0
	rod.rotate_object_local(Vector3.BACK, 0.30)
	_build_shore()
	_build_ui()
	_set_camera()

func _process(delta: float) -> void:
	_clock += delta
	var cycle := fposmod(_clock + _cycle_offset, 10.0)
	var auto_lift := cycle >= 0.7 and cycle < 2.6 or cycle >= 3.8 and cycle < 5.35
	var auto_retrieve := cycle >= 2.6 and cycle < 3.65 or cycle >= 5.35 and cycle < 6.65
	var lift := Input.is_physical_key_pressed(KEY_W) or (_auto and auto_lift)
	var retrieve := Input.is_physical_key_pressed(KEY_SPACE) or (_auto and auto_retrieve)
	var release := Input.is_physical_key_pressed(KEY_SHIFT) or (_auto and cycle >= 7.5 and cycle < 8.25)
	var lift_target := 1.0 if lift and not release else 0.0
	_lift_load = lerpf(_lift_load, lift_target, 1.0 - exp(-delta * 5.0))

	var surge := maxf(_fish_surge(cycle, 1.95, 0.28) * 0.77,
		_fish_surge(cycle, 6.92, 0.40))
	var load_amount := 0.24 + 0.05 * sin(_clock * 2.4) + _lift_load * 0.42
	if retrieve and not lift:
		load_amount += 0.09
	load_amount = clampf(load_amount + surge * 0.66, 0.0, 1.0)
	if release:
		load_amount = 0.07

	var endpoint := Vector3(-1.15 + sin(_clock * 1.16) * 0.53 - surge * 0.22,
		0.079 + sin(_clock * 4.0) * (0.012 + 0.025 * load_amount), -_distance - surge * 0.45)
	var payout := 1.4 if release else smoothstep(0.67, 1.0, surge) * 1.6
	var drive := 0.0
	if retrieve and not release:
		drive = 0.30 if lift else 1.0
	var collected: float = rod.step(delta, endpoint, load_amount, drive, payout, lift_target, surge)
	_distance = clampf(_distance - collected + lerpf(0.82, -0.45, _lift_load) * delta, 3.55, 7.45)
	_bar.value = load_amount * 100.0
	if surge > 0.40 and not release:
		_status.text = "Рывок рыбы"
	elif release:
		_status.text = "Леска ослаблена"
	elif lift:
		_status.text = "Тянешь удочку на себя"
	elif retrieve:
		_status.text = "Опускаешь и подматываешь"
	else:
		_status.text = "Удерживаешь удочку"
	for index in _rings.size():
		var phase := fposmod(_clock * 0.89 + index * 0.33, 1.0)
		var ring := _rings[index]
		ring.position = Vector3(endpoint.x, 0.015 + 0.002 * index, endpoint.z)
		ring.scale = Vector3(1.0, 0.08, 1.0) * (0.27 + phase * 1.08)
		ring.transparency = minf(0.95, phase * 0.88)

func _fish_surge(cycle: float, start: float, duration: float) -> float:
	var time := cycle - start
	return smoothstep(0.0, 0.06, time) * (1.0 - smoothstep(0.06, duration, time))

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_R:
				_close = not _close
				_set_camera()
			KEY_TAB:
				_auto = not _auto
				_distance = 5.3
				rod.deployed_m = 8.0

func _set_camera() -> void:
	if _close:
		camera.position = Vector3(-0.29, 2.09, 0.99)
		camera.look_at(rod.to_global(Vector3(-0.045, 0.186, 0.155)))
		camera.fov = 43.0
	else:
		camera.position = Vector3(0.06, 1.67, 1.22)
		camera.look_at(Vector3(0.13, 1.00, -4.0))
		camera.fov = 57.0

func _build_ui() -> void:
	var hud := CanvasLayer.new()
	add_child(hud)
	var panel := PanelContainer.new()
	panel.position = Vector2(25, 22)
	panel.custom_minimum_size = Vector2(332, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#2c3039ea")
	style.border_color = Color("#b8946e")
	style.set_border_width_all(1)
	style.set_corner_radius_all(13)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 11.0
	style.content_margin_bottom = 11.0
	panel.add_theme_stylebox_override("panel", style)
	hud.add_child(panel)
	var stack := VBoxContainer.new()
	panel.add_child(stack)
	var heading := Label.new()
	heading.text = "Натяжение лески"
	heading.add_theme_color_override("font_color", Color("#ffe3b1"))
	heading.add_theme_font_size_override("font_size", 19)
	stack.add_child(heading)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 8)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("#e7ae69")
	fill.set_corner_radius_all(4)
	_bar.add_theme_stylebox_override("fill", fill)
	stack.add_child(_bar)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	stack.add_child(_status)
	var legend := Label.new()
	legend.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	legend.offset_left = 25
	legend.offset_top = -52
	legend.text = "W  Тянуть     Пробел  Подмотка     Shift  Ослабить     R  Катушка     Tab  Автодемо"
	legend.add_theme_color_override("font_color", Color("#fff0cf"))
	legend.add_theme_color_override("font_outline_color", Color("#27242c"))
	legend.add_theme_constant_override("outline_size", 7)
	hud.add_child(legend)

func _material(hex: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(hex)
	m.roughness = 0.91
	return m

func _object(mesh: Mesh, p: Vector3, material: Material) -> MeshInstance3D:
	var obj := MeshInstance3D.new()
	obj.mesh = mesh
	obj.material_override = material
	obj.position = p
	add_child(obj)
	return obj

func _box(size: Vector3, p: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_object(mesh, p, material)

func _build_shore() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#94bdcf")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#eaddeb")
	env.ambient_light_energy = 0.43
	var surroundings := WorldEnvironment.new()
	surroundings.environment = env
	add_child(surroundings)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-43, -34, 0)
	sun.light_color = Color("#fff0de")
	sun.light_energy = 0.86
	sun.shadow_enabled = true
	add_child(sun)

	var water := PlaneMesh.new()
	water.size = Vector2(105, 110)
	var water_material := ShaderMaterial.new()
	water_material.shader = preload("water.gdshader")
	_object(water, Vector3(0, 0, -17), water_material)
	var grass := [_material("#8aa566"), _material("#75965c"), _material("#9bb071")]
	var rock := [_material("#746975"), _material("#8a7c80"), _material("#a19088")]
	var wood := [_material("#9b6650"), _material("#aa775b"), _material("#865844")]
	var leaves := [_material("#3e745e"), _material("#5d8b61"), _material("#77a267")]
	var pink := [_material("#d691ab"), _material("#e7b4a9"), _material("#e8cc77")]
	var rng := RandomNumberGenerator.new()
	rng.seed = 919
	for i in range(-8, 9):
		var x := i * 2.05
		var z := -11.4 - 2.4 * cos(x * 0.24)
		var h := rng.randf_range(0.50, 1.13)
		_box(Vector3(2.14, h + 0.65, 6.8), Vector3(x, h * 0.5 - 0.24, z - 3.4), rock[i % 3])
		_box(Vector3(2.17, 0.20, 6.83), Vector3(x, h + 0.14, z - 3.4), grass[i % 3])
		if i % 3 != 1:
			var trunk := CylinderMesh.new()
			trunk.top_radius = 0.14
			trunk.bottom_radius = 0.20
			trunk.radial_segments = 6
			trunk.height = 1.62
			_object(trunk, Vector3(x, h + 0.94, z - 1.7), wood[2])
			var crown := SphereMesh.new()
			crown.radial_segments = 7
			crown.rings = 4
			for lobe in range(5):
				var p := Vector3(x + rng.randf_range(-0.75, 0.75),
					h + rng.randf_range(1.75, 2.67), z - rng.randf_range(1.35, 2.38))
				_object(crown, p, leaves[lobe % 3]).scale = Vector3(2.15, 1.66, 1.82)
		for flower in range(4):
			_box(Vector3(0.10, 0.14, 0.10), Vector3(x + rng.randf_range(-0.9, 0.9),
				h + 0.28, z - rng.randf_range(0.32, 0.83)), pink[flower % 3])
	for i in range(9):
		_box(Vector3(2.8, 0.105, 0.172), Vector3(0, 0.92, 0.07 + i * 0.18), wood[i % 3])
	for x in [-1.36, 1.36]:
		var pole := CylinderMesh.new()
		pole.top_radius = 0.103
		pole.bottom_radius = 0.115
		pole.height = 1.66
		pole.radial_segments = 9
		_object(pole, Vector3(x, 0.56, 0.06), wood[0])
	var ripple := TorusMesh.new()
	ripple.inner_radius = 0.37
	ripple.outer_radius = 0.39
	ripple.rings = 28
	ripple.ring_segments = 5
	for i in range(3):
		_rings.append(_object(ripple, Vector3.ZERO, _material("#8cb9b9")))

```

---

## Шейдер изгиба бланка (blank.gdshader)

**Файл:** `godot/fishing_rod/blank.gdshader`

```glsl
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

```

---

## Шейдер материалов деталей удочки (parts.gdshader)

**Файл:** `godot/fishing_rod/parts.gdshader`

```glsl
shader_type spatial;

void fragment() {
	ALBEDO = COLOR.rgb;
	METALLIC = COLOR.a * 0.52;
	ROUGHNESS = mix(0.77, 0.32, clamp(COLOR.a * 1.8, 0.0, 1.0));
}

```

---

## Шейдер стилизованной воды (water.gdshader)

**Файл:** `godot/demo/water.gdshader`

```glsl
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

```

---

