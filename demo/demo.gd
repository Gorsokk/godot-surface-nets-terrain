extends Node3D
## Demo: a noise island you can dig (left click) and raise (right click).
## Démo : une île de bruit qu'on creuse (clic gauche) et qu'on élève (clic droit).
## Orbit: hold middle mouse or use A/D. Zoom: mouse wheel.

var terrain: SurfaceNetsTerrain
var cam: Camera3D
var yaw := 0.6
var pitch := -0.55
var dist := 70.0
var brush := 3.0
var info: Label


func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = Sky.new()
	e.sky.sky_material = ProceduralSkyMaterial.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)

	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.02
	terrain = SurfaceNetsTerrain.new()
	terrain.grid_size = Vector3i(72, 28, 72)
	terrain.voxel_size = 1.0
	var c := Vector2(36, 36)
	terrain.density_function = SurfaceNetsTerrain.from_heightmap(func(x: float, z: float) -> float:
		var falloff := smoothstep(0.0, 1.0, clampf(1.0 - Vector2(x, z).distance_to(c) / 33.0, 0.0, 1.0))
		return 2.0 + falloff * (12.0 + noise.get_noise_2d(x, z) * 10.0))
	terrain.position = Vector3(-36, 0, -36)
	add_child(terrain)

	var water := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	water.mesh = plane
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.12, 0.32, 0.46, 0.92)
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.roughness = 0.15
	water.material_override = wm
	water.position.y = 5.0
	add_child(water)

	cam = Camera3D.new()
	add_child(cam)
	_place_camera()

	var layer := CanvasLayer.new()
	add_child(layer)
	info = Label.new()
	info.position = Vector2(16, 12)
	info.add_theme_font_size_override("font_size", 18)
	info.add_theme_color_override("font_outline_color", Color.BLACK)
	info.add_theme_constant_override("outline_size", 6)
	layer.add_child(info)
	_update_info()
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2 and args[0] == "--screenshot":
		_screenshot.call_deferred(args[1])


## Used to make the README images: godot --path . -- --screenshot out.png
func _screenshot(path: String) -> void:
	for i in 3:
		await get_tree().process_frame
	terrain.edit(terrain.to_global(_surface(30, 34)), 5.0, false)
	terrain.edit(terrain.to_global(_surface(44, 28)), 3.5, false)
	terrain.edit(terrain.to_global(_surface(36, 46)), 3.0, true)
	_update_info()
	for i in 10:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


## Local surface point at (x, z), found by scanning the density from the top.
func _surface(x: float, z: float) -> Vector3:
	for j in range(terrain.grid_size.y - 1, -1, -1):
		var p := Vector3(x, j, z)
		if terrain.get_density(terrain.to_global(p)) > 0.0:
			return p
	return Vector3(x, 0, z)


func _place_camera() -> void:
	var dir := Vector3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw))
	cam.position = Vector3(0, 10, 0) + dir * dist
	cam.look_at(Vector3(0, 10, 0))


func _update_info() -> void:
	info.text = "Clic gauche / Left click : creuser / dig\nClic droit / Right click : élever / raise\n" \
		+ "Molette / Wheel : zoom   ·   [ ] : pinceau / brush %.1f m\nA / D ou clic milieu : tourner / orbit\n" % brush \
		+ "Modifications / Edits : %d   ·   Chunks : %d" % [terrain.edits.size(), terrain.get_chunk_count()]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT:
				var hit := _raycast(event.position)
				if hit:
					terrain.edit(hit.position, brush, event.button_index == MOUSE_BUTTON_RIGHT)
					_update_info()
			MOUSE_BUTTON_WHEEL_UP:
				dist = maxf(15.0, dist - 4.0)
				_place_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				dist = minf(160.0, dist + 4.0)
				_place_camera()
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		yaw -= event.relative.x * 0.005
		pitch = clampf(pitch - event.relative.y * 0.005, -1.4, -0.1)
		_place_camera()
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_BRACKETLEFT:
			brush = maxf(1.0, brush - 0.5)
		elif event.keycode == KEY_BRACKETRIGHT:
			brush = minf(10.0, brush + 0.5)
		_update_info()


func _process(delta: float) -> void:
	var turn := Input.get_axis("ui_left", "ui_right")
	if Input.is_physical_key_pressed(KEY_A):
		turn -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		turn += 1.0
	if turn != 0.0:
		yaw += turn * delta * 1.2
		_place_camera()


func _raycast(screen_pos: Vector2) -> Dictionary:
	var from := cam.project_ray_origin(screen_pos)
	var to := from + cam.project_ray_normal(screen_pos) * 1000.0
	return get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
