class_name SurfaceNetsTerrain
extends Node3D
## Smooth, editable voxel terrain in pure GDScript (no engine module, no custom Godot build).
##
## Method: "surface nets" (a cousin of marching cubes). Each grid point stores a density:
## positive = solid, negative = air. The surface passes where the sign changes.
## The volume is split into chunks: an edit only rebuilds the chunks it touches.
##
## Every edit is recorded in [member edits], so a late-joining player (or a save file)
## can rebuild exactly the same terrain with [method replay].
##
## Terrain voxel lisse et modifiable, en GDScript pur (aucun module, aucune version spéciale de Godot).

## Emitted after a chunk mesh (and its collision) has been rebuilt.
signal chunk_rebuilt(chunk: Vector3i)
## Emitted after each edit, with the values you need to send over the network.
signal edited(center: Vector3, radius: float, add: bool)

## Number of grid points on each axis.
@export var grid_size := Vector3i(64, 24, 64)
## Size of one voxel, in metres.
@export var voxel_size := 1.0
## Cells per chunk side. Smaller = faster edits, more nodes.
@export_range(4, 64) var chunk_cells := 16
## Faceted low-poly look (true) or smooth normals (false).
@export var flat_shading := true
## Material for the terrain. If empty, a vertex-colour material is created.
@export var material: Material
## Build collision shapes (needed for physics and raycasts).
@export var generate_collision := true
## Generate the terrain automatically when the node enters the tree.
@export var generate_on_ready := true

## func(p: Vector3) -> float, in local metres. Positive = solid. Default: flat ground at mid height.
var density_function: Callable
## Optional func(center: Vector3, normal: Vector3, original_density: float) -> Color for vertex colours.
var color_function: Callable
## Edit log: each entry is [center: Vector3 (local), radius: float, add: bool].
var edits: Array = []

const _EDGES := [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]

var _d := PackedFloat32Array()
var _chunks := {}
var _mat: Material


func _ready() -> void:
	if generate_on_ready:
		generate()


## Builds a density function from a height function func(x: float, z: float) -> float.
static func from_heightmap(height: Callable) -> Callable:
	return func(p: Vector3) -> float: return height.call(p.x, p.z) - p.y


## (Re)generates the whole terrain from [member density_function], then replays [member edits].
func generate() -> void:
	for c in _chunks.values():
		c.queue_free()
	_chunks.clear()
	_mat = material
	if _mat == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = 1.0
		_mat = m
	if not density_function.is_valid():
		var ground := grid_size.y * voxel_size * 0.5
		density_function = func(p: Vector3) -> float: return ground - p.y
	var nx := grid_size.x
	var ny := grid_size.y
	var nz := grid_size.z
	_d.resize(nx * ny * nz)
	for k in nz:
		for j in ny:
			for i in nx:
				var p := Vector3(i, j, k) * voxel_size
				_d[i + nx * (j + ny * k)] = clampf(density_function.call(p) / voxel_size, -4.0, 4.0)
	var old := edits.duplicate()
	edits.clear()
	for e in old:
		_apply_sphere(e[0], e[1], e[2])
		edits.append(e)
	for cx in _count(nx):
		for cy in _count(ny):
			for cz in _count(nz):
				_build_chunk(Vector3i(cx, cy, cz))


## Digs (add = false) or raises (add = true) a sphere. [param global_center] is in world space.
func edit(global_center: Vector3, radius: float, add: bool) -> void:
	var sc := global_transform.basis.get_scale().x if is_inside_tree() else 1.0
	edit_local(_to_local(global_center), radius / sc, add)


## Same as [method edit], with a centre in this node's local space (use this for networking).
func edit_local(center: Vector3, radius: float, add: bool) -> void:
	var touched := _apply_sphere(center, radius, add)
	edits.append([center, radius, add])
	for c in touched:
		_build_chunk(c)
	edited.emit(center, radius, add)


## Rebuilds the terrain from an edit log (for example one received from the host).
func replay(log: Array) -> void:
	edits = log.duplicate()
	generate()


## True if the given world position is inside solid matter.
func is_solid(global_pos: Vector3) -> bool:
	return get_density(global_pos) > 0.0


## Density at a world position (nearest grid point). Outside the grid: -4 (air).
func get_density(global_pos: Vector3) -> float:
	var g := (_to_local(global_pos) / voxel_size).round()
	var i := int(g.x)
	var j := int(g.y)
	var k := int(g.z)
	if i < 0 or j < 0 or k < 0 or i >= grid_size.x or j >= grid_size.y or k >= grid_size.z:
		return -4.0
	return _d[i + grid_size.x * (j + grid_size.y * k)]


## Number of chunk nodes currently holding geometry.
func get_chunk_count() -> int:
	return _chunks.size()


# ---------------------------------------------------------------- internals

func _to_local(p: Vector3) -> Vector3:
	return to_local(p) if is_inside_tree() else p


func _count(n: int) -> int:
	return int(ceil(float(n - 1) / chunk_cells))


func _v(i: int, j: int, k: int) -> float:
	return _d[i + grid_size.x * (j + grid_size.y * k)]


func _apply_sphere(center: Vector3, radius: float, add: bool) -> Dictionary:
	var nx := grid_size.x
	var ny := grid_size.y
	var nz := grid_size.z
	var s := voxel_size
	var lo := ((center - Vector3.ONE * (radius + s)) / s).floor()
	var hi := ((center + Vector3.ONE * (radius + s)) / s).ceil()
	var i0: int = clampi(int(lo.x), 0, nx - 1)
	var j0: int = clampi(int(lo.y), 1, ny - 1)  # never pierce the bottom of the world
	var k0: int = clampi(int(lo.z), 0, nz - 1)
	var i1: int = clampi(int(hi.x), 0, nx - 1)
	var j1: int = clampi(int(hi.y), 0, ny - 2)  # nor the ceiling
	var k1: int = clampi(int(hi.z), 0, nz - 1)
	for k in range(k0, k1 + 1):
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var sdf := (Vector3(i, j, k) * s).distance_to(center) / s - radius / s
				var id := i + nx * (j + ny * k)
				_d[id] = maxf(_d[id], -sdf) if add else minf(_d[id], sdf)
	var touched := {}
	var last := Vector3i(_count(nx) - 1, _count(ny) - 1, _count(nz) - 1)
	for k in range(maxi(k0 - 1, 0), k1 + 1):
		for j in range(maxi(j0 - 1, 0), j1 + 1):
			for i in range(maxi(i0 - 1, 0), i1 + 1):
				var c := Vector3i(mini(i / chunk_cells, last.x), mini(j / chunk_cells, last.y), mini(k / chunk_cells, last.z))
				touched[c] = true
	return touched


func _cell_vertex(i: int, j: int, k: int, cache: Dictionary) -> Vector3:
	var key := i + grid_size.x * (j + grid_size.y * k)
	if cache.has(key):
		return cache[key]
	var v: Array[float] = []
	var offs: Array[Vector3] = []
	for c in 8:
		var o := Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1)
		offs.append(o)
		v.append(_v(i + int(o.x), j + int(o.y), k + int(o.z)))
	var sum := Vector3.ZERO
	var n := 0
	for e in _EDGES:
		var va: float = v[e[0]]
		var vb: float = v[e[1]]
		if (va > 0.0) != (vb > 0.0):
			sum += offs[e[0]].lerp(offs[e[1]], va / (va - vb))
			n += 1
	var p := (Vector3(i, j, k) + sum / float(maxi(n, 1))) * voxel_size
	cache[key] = p
	return p


func _build_chunk(c: Vector3i) -> void:
	var nx := grid_size.x
	var ny := grid_size.y
	var nz := grid_size.z
	var i0 := c.x * chunk_cells
	var j0 := c.y * chunk_cells
	var k0 := c.z * chunk_cells
	var i1: int = mini(i0 + chunk_cells, nx - 1)
	var j1: int = mini(j0 + chunk_cells, ny - 1)
	var k1: int = mini(k0 + chunk_cells, nz - 1)
	var cache := {}
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1 if flat_shading else 0)
	var faces := PackedVector3Array()
	for k in range(k0, k1):
		for j in range(j0, j1):
			for i in range(i0, i1):
				var inside := _v(i, j, k) > 0.0
				if j >= 1 and k >= 1 and j <= ny - 2 and k <= nz - 2 and (_v(i + 1, j, k) > 0.0) != inside:
					_quad(st, faces, _cell_vertex(i, j - 1, k - 1, cache), _cell_vertex(i, j, k - 1, cache),
						_cell_vertex(i, j, k, cache), _cell_vertex(i, j - 1, k, cache), Vector3.RIGHT if inside else Vector3.LEFT)
				if i >= 1 and k >= 1 and i <= nx - 2 and k <= nz - 2 and (_v(i, j + 1, k) > 0.0) != inside:
					_quad(st, faces, _cell_vertex(i - 1, j, k - 1, cache), _cell_vertex(i, j, k - 1, cache),
						_cell_vertex(i, j, k, cache), _cell_vertex(i - 1, j, k, cache), Vector3.UP if inside else Vector3.DOWN)
				if i >= 1 and j >= 1 and i <= nx - 2 and j <= ny - 2 and (_v(i, j, k + 1) > 0.0) != inside:
					_quad(st, faces, _cell_vertex(i - 1, j - 1, k, cache), _cell_vertex(i, j - 1, k, cache),
						_cell_vertex(i, j, k, cache), _cell_vertex(i - 1, j, k, cache), Vector3.BACK if inside else Vector3.FORWARD)
	var node: StaticBody3D = _chunks.get(c)
	if faces.is_empty():
		if node:
			node.queue_free()
			_chunks.erase(c)
		return
	st.generate_normals()
	var mesh := st.commit()
	if node == null:
		node = StaticBody3D.new()
		node.name = "Chunk_%d_%d_%d" % [c.x, c.y, c.z]
		node.set_meta("surface_nets_terrain", true)
		var mi := MeshInstance3D.new()
		mi.material_override = _mat
		node.add_child(mi)
		if generate_collision:
			var cs := CollisionShape3D.new()
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = false  # faces point to the air: one side is enough
			cs.shape = shape
			node.add_child(cs)
		add_child(node)
		_chunks[c] = node
	(node.get_child(0) as MeshInstance3D).mesh = mesh
	if generate_collision:
		((node.get_child(1) as CollisionShape3D).shape as ConcavePolygonShape3D).set_faces(faces)
	chunk_rebuilt.emit(c)


func _quad(st: SurfaceTool, faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, e: Vector3, out: Vector3) -> void:
	_tri(st, faces, a, b, c, out)
	_tri(st, faces, a, c, e, out)


## One triangle, flipped if needed so that it faces the air.
func _tri(st: SurfaceTool, faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, out: Vector3) -> void:
	var n := (a - c).cross(a - b)
	if n.length_squared() < 0.000001:
		return
	if n.dot(out) < 0.0:
		var t := b
		b = c
		c = t
		n = -n
	var col := _color((a + b + c) / 3.0, n.normalized())
	for p in [a, b, c]:
		st.set_color(col)
		st.add_vertex(p)
		faces.append(p)


func _color(m: Vector3, n: Vector3) -> Color:
	var orig: float = density_function.call(m)
	if color_function.is_valid():
		return color_function.call(m, n, orig)
	var jitter := fposmod(sin(m.x * 12.9898 + m.z * 78.233 + m.y * 37.719) * 43758.5453, 1.0) * 0.08
	var col: Color
	if orig > 0.9 * voxel_size:
		col = Color(0.2, 0.16, 0.17)   # dug into the original ground
	elif orig < -0.9 * voxel_size:
		col = Color(0.5, 0.38, 0.26)   # raised earth
	elif n.y < 0.6:
		col = Color(0.5, 0.46, 0.42)   # rock on slopes
	else:
		col = Color(0.27, 0.47, 0.2)   # grass
	return col.darkened(jitter)
