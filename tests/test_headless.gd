extends SceneTree
## Headless check: godot --headless --path . --script res://tests/test_headless.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	print(("  OK   " if cond else "  FAIL ") + what)
	if not cond:
		failures += 1


func _initialize() -> void:
	var root3d := Node3D.new()
	root.add_child(root3d)

	var t := SurfaceNetsTerrain.new()
	t.grid_size = Vector3i(33, 17, 33)
	t.voxel_size = 1.0
	t.chunk_cells = 16
	t.generate_on_ready = false
	t.density_function = SurfaceNetsTerrain.from_heightmap(func(x: float, z: float) -> float: return 8.0)
	root3d.add_child(t)
	await process_frame
	var t0 := Time.get_ticks_msec()
	t.generate()
	print("generate: %d ms, %d chunks" % [Time.get_ticks_msec() - t0, t.get_chunk_count()])

	check(t.get_chunk_count() > 0, "chunks were built")
	check(t.is_solid(Vector3(16, 4, 16)), "below the ground is solid")
	check(not t.is_solid(Vector3(16, 12, 16)), "above the ground is air")

	var rebuilt := [0]
	t.chunk_rebuilt.connect(func(_c): rebuilt[0] += 1)
	t0 = Time.get_ticks_msec()
	t.edit(Vector3(16, 8, 16), 3.0, false)
	print("dig: %d ms, %d chunks rebuilt" % [Time.get_ticks_msec() - t0, rebuilt[0]])
	check(not t.is_solid(Vector3(16, 6, 16)), "dig removed matter")
	check(rebuilt[0] > 0 and rebuilt[0] < 8, "only touched chunks were rebuilt")

	t.edit(Vector3(5, 9, 5), 2.0, true)
	check(t.is_solid(Vector3(5, 9.5, 5)), "raise added matter")
	check(t.edits.size() == 2, "edit log has 2 entries")

	# A second terrain replaying the log must end up identical.
	var t2 := SurfaceNetsTerrain.new()
	t2.grid_size = t.grid_size
	t2.generate_on_ready = false
	t2.density_function = t.density_function
	root3d.add_child(t2)
	t2.replay(t.edits)
	var same := true
	for p in [Vector3(16, 6, 16), Vector3(5, 9.5, 5), Vector3(10, 7, 20), Vector3(16, 8, 18)]:
		if t.get_density(p) != t2.get_density(p):
			same = false
	check(same, "replayed terrain matches the original")

	# Collision exists: a ray hits the ground.
	await physics_frame
	await physics_frame
	var hit := root3d.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(Vector3(25, 30, 25), Vector3(25, -10, 25)))
	check(not hit.is_empty() and absf(hit.position.y - 8.0) < 1.0, "raycast hits the surface near y=8")

	print("RESULT: %s" % ("PASS" if failures == 0 else "%d FAILURE(S)" % failures))
	quit(failures)
