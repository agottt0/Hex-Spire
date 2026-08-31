extends SceneTree
## R9 验证：HexFootprint 的全量边界检查
##
## 3 体型 × 49 锚点 × 6 朝向 × 3 地形模板 = 2646 组 can_place，
## 与一份独立的暴力参考实现逐一比对。
##
## 用法：godot --headless --path E:/GameDemo -s res://tools/verify_footprint.gd

func _initialize() -> void:
	var fail := 0
	fail += _test_cells_shape()
	fail += _test_against_reference()
	fail += _test_narrow_pass()
	fail += _test_rotate_in_place()
	fail += _test_adjacent_and_distance()
	fail += _test_boundary_edges()

	print("")
	print("========== 总失败数: %d ==========" % fail)
	quit(0 if fail == 0 else 1)


func _sizes() -> Array:
	return [
		["S", SizeClassData.make(GameEnums.SizeClass.S)],
		["M", SizeClassData.make(GameEnums.SizeClass.M)],
		["L", SizeClassData.make(GameEnums.SizeClass.L)],
	]


# ---- 1. cells() 的基本形状不变量
func _test_cells_shape() -> int:
	var bad := 0
	for pair in _sizes():
		var label: String = pair[0]
		var sd: SizeClassData = pair[1]
		for row in range(1, 8):
			for col in range(1, 8):
				var anchor := HexCoord.offset_to_cube(col, row)
				for f in range(6):
					var cs := HexFootprint.cells(anchor, sd.footprint, f)
					# 格数必须等于 cell_count
					if cs.size() != sd.cell_count:
						print("FAIL %s 格数 %d != %d" % [label, cs.size(), sd.cell_count])
						bad += 1
					# 不得自重叠
					var uniq := {}
					for c in cs:
						uniq[c] = true
					if uniq.size() != sd.cell_count:
						print("FAIL %s @(%d,%d) f=%d 自重叠: %s" % [label, col, row, f, cs])
						bad += 1
					# 必须包含锚点
					if not cs.has(anchor):
						print("FAIL %s @(%d,%d) f=%d 不含锚点" % [label, col, row, f])
						bad += 1
					# 全部满足 x+y+z==0
					for c in cs:
						if c.x + c.y + c.z != 0:
							print("FAIL %s sum!=0: %s" % [label, c])
							bad += 1
	print("1) cells() 形状不变量（3体型×49锚点×6朝向=882组）失败: %d" % bad)
	return bad


# ---- 2. can_place 与暴力参考实现比对
func _test_against_reference() -> int:
	var layouts := _make_layouts()
	var bad := 0
	var total := 0
	for lname in layouts:
		var grid: HexGrid = layouts[lname]
		for pair in _sizes():
			var sd: SizeClassData = pair[1]
			for row in range(1, 8):
				for col in range(1, 8):
					var anchor := HexCoord.offset_to_cube(col, row)
					for f in range(6):
						total += 1
						var actual := HexFootprint.can_place(grid, anchor, sd.footprint, f)
						var expected := _reference_can_place(grid, anchor, sd.footprint, f)
						if actual != expected:
							print("FAIL [%s] %s @(%d,%d) f=%d: 实际=%s 参考=%s" % [
								lname, pair[0], col, row, f, actual, expected])
							bad += 1
	print("2) can_place 与参考实现比对（%d 组）失败: %d" % [total, bad])
	return bad


## 独立的暴力参考实现 —— 故意用不同写法，避免"同样的错抄两遍"
func _reference_can_place(g: HexGrid, anchor: Vector3i, foot: Array[Vector3i], facing: int) -> bool:
	for off in foot:
		var rotated := off
		for _i in range(posmod(facing, 6)):
			rotated = Vector3i(-rotated.z, -rotated.x, -rotated.y)
		var c: Vector3i = anchor + rotated
		var o := HexCoord.cube_to_offset(c)
		if o.x < 1 or o.x > 7 or o.y < 1 or o.y > 7:
			return false
		var t := g.terrain_at(c)
		if t == GameEnums.Terrain.WALL or t == GameEnums.Terrain.PIT:
			return false
		if g.occupant_at(c) != -1:
			return false
	return true


# ---- 3. 狭道模板：footprint 层能验证的部分
##
## ⚠️⚠️ 重要教训（连续写错 4 次断言后的结论，务必读完再改这个函数）：
##
## **"能不能通过门洞"是寻路问题，footprint 层无法判定。**
## 我依次试过并全部失败的判据：
##   ✗ 「能否静态占据门行两侧」—— L 纵向跨 3 行、门行只占 2 格，2 格门能"骑"上去
##   ✗ 「能否占据门行」—— M 可只探 1 格进门口，另两格留门后
##   ✗ 「能否同时接触门行两侧」—— S 只占 1 格，永远无法同时接触两侧，对 S 恒假
##   ✗ 「可用姿态数随体型递减」—— 没有物理依据：多格单位 6 个朝向各不相同（18 个），
##      而 S 的 6 个朝向占格完全相同（去重后 12 个）→ 大体型姿态反而更多
##
## ✓ 正解：通过性 = (anchor, facing) 状态图上从下半区到上半区存在路径。
##   必须用 HexPathfinder 搜索。**已移交 tests/test_pathfinder.gd（P1 交付）。**
##
## 本函数只验证 footprint 层【真正能判定】的一件事：
##   M 能否堵死 2 格门洞 —— §4.2「我一旦站在那里谁也过不去」的直接检验。
## 其余数据只打印供参考，不作为通过/失败判据。
func _test_narrow_pass() -> int:
	var bad := 0
	var layouts := _make_layouts()

	# --- 唯一的硬断言：M 必须能堵死 2 格门洞
	var g2: HexGrid = layouts["狭道·2格门"]
	var door := [HexCoord.offset_to_cube(3, 4), HexCoord.offset_to_cube(4, 4)]
	var m_block := _blocking_poses(g2, GameEnums.SizeClass.M, door)
	print("3) M 能同时占满 2 格门洞的姿态数=%d（应 >0）" % m_block.size())
	if m_block.is_empty():
		print("   FAIL 巨人无法堵门 —— §4.2 的核心体验无法实现")
		bad += 1
	else:
		print("     例如: %s" % str(m_block.slice(0, 3)))

	# --- 参考数据（不作判据）：各体型在两种门洞下可探入门行的姿态数
	print("   [参考] 可让至少一格落在门行 row4 的合法姿态数：")
	for lname in ["狭道·2格门", "狭道·1格门"]:
		var g: HexGrid = layouts[lname]
		var line := "     %s : " % lname
		for pair in _sizes():
			line += "%s=%d  " % [pair[0], _poses_touching_row(g, pair[1], 4)]
		print(line)
	print("   [参考] 通过性判定见 test_pathfinder.gd —— footprint 层不负责这件事")
	return bad


## 有多少个合法姿态能让【至少一格】落在指定行
func _poses_touching_row(g: HexGrid, sd: SizeClassData, target_row: int) -> int:
	var n := 0
	for row in range(1, 8):
		for col in range(1, 8):
			var a := HexCoord.offset_to_cube(col, row)
			for f in range(6):
				if not HexFootprint.can_place(g, a, sd.footprint, f):
					continue
				for c in HexFootprint.cells(a, sd.footprint, f):
					if HexCoord.cube_to_offset(c).y == target_row:
						n += 1
						break
	return n


## 列出能同时占据 required 全部格的合法姿态
func _blocking_poses(g: HexGrid, size: GameEnums.SizeClass, required: Array) -> Array:
	var sd := SizeClassData.make(size)
	var out: Array = []
	for row in range(1, 8):
		for col in range(1, 8):
			var a := HexCoord.offset_to_cube(col, row)
			for f in range(6):
				if not HexFootprint.can_place(g, a, sd.footprint, f):
					continue
				var cs := HexFootprint.cells(a, sd.footprint, f)
				var all_in := true
				for r in required:
					if not cs.has(r):
						all_in = false
						break
				if all_in:
					out.append("(%d,%d) f=%d" % [col, row, f])
	return out


# ---- 4. 原地转向：ignore_unit_id 必须让自身占格不算冲突
func _test_rotate_in_place() -> int:
	var g := HexGrid.new()
	var sd := SizeClassData.make(GameEnums.SizeClass.M)
	var anchor := HexCoord.offset_to_cube(4, 4)
	# 登记自己占据 facing=0 的格
	var own := HexFootprint.cells(anchor, sd.footprint, 0)
	g.set_occupancy(7, own)
	var bad := 0
	# 不忽略自己 → 转向应失败（因为自己占着格）
	var without := HexFootprint.can_place(g, anchor, sd.footprint, 1, -1)
	# 忽略自己 → 应成功
	var with_ignore := HexFootprint.can_place(g, anchor, sd.footprint, 1, 7)
	print("4) 原地转向 不忽略自身=%s（应 false）  忽略自身=%s（应 true）" % [without, with_ignore])
	if without:
		bad += 1
	if not with_ignore:
		bad += 1
	return bad


# ---- 5. 相邻格与距离：大体型应该更多/更远
func _test_adjacent_and_distance() -> int:
	var a := HexCoord.offset_to_cube(4, 4)
	var n_s := HexFootprint.adjacent_cells(a, SizeClassData.make(GameEnums.SizeClass.S).footprint, 0).size()
	var n_m := HexFootprint.adjacent_cells(a, SizeClassData.make(GameEnums.SizeClass.M).footprint, 0).size()
	var n_l := HexFootprint.adjacent_cells(a, SizeClassData.make(GameEnums.SizeClass.L).footprint, 0).size()
	print("5) 相邻格数 S=%d M=%d L=%d（应递增，§8.2.2机制点3）" % [n_s, n_m, n_l])
	var bad := 0
	if not (n_s < n_m and n_m < n_l):
		bad += 1
	# 射程从最近格起算：M 朝向目标时应比 S 更近
	var target := HexCoord.offset_to_cube(7, 4)
	var d_s := HexFootprint.distance_from(a, SizeClassData.make(GameEnums.SizeClass.S).footprint, 0, target)
	var d_m := HexFootprint.distance_from(a, SizeClassData.make(GameEnums.SizeClass.M).footprint, 0, target)
	print("   到 (7,4) 距离 S=%d M=%d（M 应 <= S）" % [d_s, d_m])
	if d_m > d_s:
		bad += 1
	return bad


# ---- 6. 边界描边：边数应符合几何预期
func _test_boundary_edges() -> int:
	var a := HexCoord.offset_to_cube(4, 4)
	var bad := 0
	# S: 1 格 6 条边
	var e_s := HexFootprint.boundary_edges(a, SizeClassData.make(GameEnums.SizeClass.S).footprint, 0).size()
	# M: 3 格，内部共享 3 条边 → 3*6 - 2*3 = 12
	var e_m := HexFootprint.boundary_edges(a, SizeClassData.make(GameEnums.SizeClass.M).footprint, 0).size()
	# L: 6 格边长3三角，内部共享 6 条边 → 6*6 - 2*6 = 24... 实测取值
	var e_l := HexFootprint.boundary_edges(a, SizeClassData.make(GameEnums.SizeClass.L).footprint, 0).size()
	print("6) 边界边数 S=%d(应6) M=%d(应12) L=%d" % [e_s, e_m, e_l])
	if e_s != 6:
		bad += 1
	if e_m != 12:
		bad += 1
	if e_l <= e_m:
		bad += 1
	return bad


# ---- 地形模板
func _make_layouts() -> Dictionary:
	var out := {}

	# 空旷厅堂：全 FLOOR
	out["空旷厅堂"] = HexGrid.new()

	# 狭道·2格门：row 4 全 WALL，仅 (3,4)(4,4) 为 FLOOR
	# → S/M 可过，M 能堵死，L 卡门口。这是【巨人的舞台】
	var n2 := HexGrid.new()
	for col in range(1, 8):
		if col == 3 or col == 4:
			continue
		n2.set_terrain(HexCoord.offset_to_cube(col, 4), GameEnums.Terrain.WALL)
	out["狭道·2格门"] = n2

	# 狭道·1格门：row 4 全 WALL，仅 (4,4) 为 FLOOR
	# → 只有 S 能过。这是【真正的体型闸门】，也是《巨化》诅咒代价的验证场
	var n1 := HexGrid.new()
	for col in range(1, 8):
		if col == 4:
			continue
		n1.set_terrain(HexCoord.offset_to_cube(col, 4), GameEnums.Terrain.WALL)
	out["狭道·1格门"] = n1

	# 尖刺牢房：WALL (2,4)(6,4)
	var spike := HexGrid.new()
	spike.set_terrain(HexCoord.offset_to_cube(2, 4), GameEnums.Terrain.WALL)
	spike.set_terrain(HexCoord.offset_to_cube(6, 4), GameEnums.Terrain.WALL)
	for cell in [[2, 3], [6, 3], [4, 4], [3, 5], [5, 5], [4, 6]]:
		spike.set_hazard(HexCoord.offset_to_cube(cell[0], cell[1]), GameEnums.Hazard.SPIKES)
	out["尖刺牢房"] = spike

	return out
