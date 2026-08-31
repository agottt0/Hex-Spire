class_name HexGrid
extends RefCounted
## 7×7 六边形战场的格子容器 —— 策划案 §8.3
##
## 纯逻辑，零 Node 依赖（纪律 3）。可序列化（纪律 2/5）。
##
## 格子属性（§8.3）：terrain / hazard / feature / occupant

var cols: int = K.BOARD_COLS
var rows: int = K.BOARD_ROWS

## 以立方坐标为键的稀疏存储。只存在界内的格。
var _terrain: Dictionary = {}   # Vector3i -> GameEnums.Terrain
var _hazard: Dictionary = {}    # Vector3i -> GameEnums.Hazard
var _feature: Dictionary = {}   # Vector3i -> GameEnums.Feature
var _occupant: Dictionary = {}  # Vector3i -> unit_id (int)

## 确定性遍历用：按 (row, col) 升序的全部界内格
var _all_cells: Array[Vector3i] = []


func _init(p_cols: int = K.BOARD_COLS, p_rows: int = K.BOARD_ROWS) -> void:
	cols = p_cols
	rows = p_rows
	_rebuild_cells()


func _rebuild_cells() -> void:
	_all_cells.clear()
	_terrain.clear()
	_hazard.clear()
	_feature.clear()
	_occupant.clear()
	# ⚠️ 按 row 再 col 的固定顺序生成 —— 纪律 5：禁止依赖 Dictionary 遍历顺序，
	#    需要顺序时用显式排序的 Array
	for row in range(1, rows + 1):
		for col in range(1, cols + 1):
			var c := HexCoord.offset_to_cube(col, row)
			_all_cells.append(c)
			_terrain[c] = GameEnums.Terrain.FLOOR
			_hazard[c] = GameEnums.Hazard.NONE
			_feature[c] = GameEnums.Feature.NONE


## 全部界内格，按 (row, col) 升序。确定性遍历的唯一入口。
func all_cells() -> Array[Vector3i]:
	return _all_cells


func in_bounds(c: Vector3i) -> bool:
	var o := HexCoord.cube_to_offset(c)
	return o.x >= 1 and o.x <= cols and o.y >= 1 and o.y <= rows


# ------------------------------------------------------------------ 地形

func terrain_at(c: Vector3i) -> GameEnums.Terrain:
	return _terrain.get(c, GameEnums.Terrain.WALL)


func set_terrain(c: Vector3i, t: GameEnums.Terrain) -> void:
	if in_bounds(c):
		_terrain[c] = t


## 可通行判定。§8.3
##   WALL 永不可通行；PIT 不可通行（除非会飞，本 demo 不做）；
##   RUBBLE 可通行但移动成本 +1，L 体型可压碎。
func is_walkable(c: Vector3i, can_crush_rubble: bool = false) -> bool:
	if not in_bounds(c):
		return false
	var t: GameEnums.Terrain = terrain_at(c)
	match t:
		GameEnums.Terrain.WALL:
			return false
		GameEnums.Terrain.PIT:
			return false
		GameEnums.Terrain.RUBBLE:
			return true  # 可进入，成本更高；can_crush_rubble 影响的是成本不是可否
		_:
			return true


## 移动成本。RUBBLE +1（L 体型压碎后为 0 额外）
func move_cost_at(c: Vector3i, can_crush_rubble: bool = false) -> int:
	if terrain_at(c) == GameEnums.Terrain.RUBBLE and not can_crush_rubble:
		return 2
	return 1


# ------------------------------------------------------------------ 危害

func hazard_at(c: Vector3i) -> GameEnums.Hazard:
	return _hazard.get(c, GameEnums.Hazard.NONE)


func set_hazard(c: Vector3i, h: GameEnums.Hazard) -> void:
	if in_bounds(c):
		_hazard[c] = h


func hazard_cells() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in _all_cells:
		if hazard_at(c) != GameEnums.Hazard.NONE:
			out.append(c)
	return out


# ------------------------------------------------------------------ 地物

func feature_at(c: Vector3i) -> GameEnums.Feature:
	return _feature.get(c, GameEnums.Feature.NONE)


func set_feature(c: Vector3i, f: GameEnums.Feature) -> void:
	if in_bounds(c):
		_feature[c] = f


# ------------------------------------------------------------------ 占据

## 返回占据该格的 unit_id，无则 -1
func occupant_at(c: Vector3i) -> int:
	return _occupant.get(c, -1)


## 登记一个单位占据的全部格。调用前应已通过 HexFootprint.can_place。
func set_occupancy(unit_id: int, cells: Array[Vector3i]) -> void:
	for c in cells:
		_occupant[c] = unit_id


## 清除某单位的全部占格
func clear_occupancy(unit_id: int) -> void:
	var to_del: Array[Vector3i] = []
	for c in _all_cells:
		if _occupant.get(c, -1) == unit_id:
			to_del.append(c)
	for c in to_del:
		_occupant.erase(c)


func cells_of_unit(unit_id: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in _all_cells:
		if _occupant.get(c, -1) == unit_id:
			out.append(c)
	return out


func is_empty(c: Vector3i) -> bool:
	return in_bounds(c) and is_walkable(c) and occupant_at(c) == -1


# ------------------------------------------------------------------ 范围与视线

## 以 center 为中心、半径 r 的全部界内格（含中心）
func cells_in_range(center: Vector3i, r: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in _all_cells:
		if HexCoord.distance(center, c) <= r:
			out.append(c)
	return out


## 环形：距离恰为 r
func cells_in_ring(center: Vector3i, r: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in _all_cells:
		if HexCoord.distance(center, c) == r:
			out.append(c)
	return out


## 直线：从 origin 朝 dir_index 走 len 格（遇 WALL 停止）
func cells_in_line(origin: Vector3i, dir_index: int, length: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var cur := origin
	var d := HexCoord.DIRS[posmod(dir_index, 6)]
	for _i in range(length):
		cur = cur + d
		if not in_bounds(cur):
			break
		out.append(cur)
		if terrain_at(cur) == GameEnums.Terrain.WALL:
			break
	return out


## 视线判定：WALL 与 PILLAR 阻断。用立方坐标线性插值取样。
func has_line_of_sight(from: Vector3i, to: Vector3i) -> bool:
	if from == to:
		return true
	var n := HexCoord.distance(from, to)
	for i in range(1, n):
		var t := float(i) / float(n)
		var s := _cube_lerp_round(from, to, t)
		if s == from or s == to:
			continue
		if terrain_at(s) == GameEnums.Terrain.WALL:
			return false
		if feature_at(s) == GameEnums.Feature.PILLAR:
			return false
	return true


static func _cube_lerp_round(a: Vector3i, b: Vector3i, t: float) -> Vector3i:
	var x := lerpf(float(a.x), float(b.x), t)
	var y := lerpf(float(a.y), float(b.y), t)
	var z := lerpf(float(a.z), float(b.z), t)
	# 立方坐标四舍五入：修正误差最大的那一维，保证 x+y+z==0
	var rx := roundf(x)
	var ry := roundf(y)
	var rz := roundf(z)
	var dx := absf(rx - x)
	var dy := absf(ry - y)
	var dz := absf(rz - z)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector3i(int(rx), int(ry), int(rz))


# ------------------------------------------------------------------ 序列化（纪律 2/5）

func to_dict() -> Dictionary:
	# 用 offset 坐标做键的字符串形式，便于 JSON 化与人工阅读
	var terr := {}
	var haz := {}
	var feat := {}
	for c in _all_cells:
		var o := HexCoord.cube_to_offset(c)
		var key := "%d,%d" % [o.x, o.y]
		if terrain_at(c) != GameEnums.Terrain.FLOOR:
			terr[key] = int(terrain_at(c))
		if hazard_at(c) != GameEnums.Hazard.NONE:
			haz[key] = int(hazard_at(c))
		if feature_at(c) != GameEnums.Feature.NONE:
			feat[key] = int(feature_at(c))
	var occ := {}
	for c in _all_cells:
		var uid := occupant_at(c)
		if uid != -1:
			var o2 := HexCoord.cube_to_offset(c)
			occ["%d,%d" % [o2.x, o2.y]] = uid
	return {"cols": cols, "rows": rows, "terrain": terr, "hazard": haz, "feature": feat, "occupant": occ}


static func from_dict(d: Dictionary) -> HexGrid:
	var g := HexGrid.new(d.get("cols", K.BOARD_COLS), d.get("rows", K.BOARD_ROWS))
	for key in d.get("terrain", {}):
		g.set_terrain(_key_to_cube(key), d["terrain"][key])
	for key in d.get("hazard", {}):
		g.set_hazard(_key_to_cube(key), d["hazard"][key])
	for key in d.get("feature", {}):
		g.set_feature(_key_to_cube(key), d["feature"][key])
	for key in d.get("occupant", {}):
		g._occupant[_key_to_cube(key)] = d["occupant"][key]
	return g


static func _key_to_cube(key: String) -> Vector3i:
	var parts := key.split(",")
	return HexCoord.offset_to_cube(int(parts[0]), int(parts[1]))


func duplicate_grid() -> HexGrid:
	return HexGrid.from_dict(to_dict())
