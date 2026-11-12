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
