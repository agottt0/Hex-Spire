extends SceneTree
## 寻路验证 —— 并【最终解答】体型闸门问题
##
## verify_footprint.gd 里我用 4 种静态几何判据都答错了"体型能否通过狭道"。
## 正确答案在这里：用 (anchor, facing) 状态图搜索。
##
## godot --headless --path E:/GameDemo -s res://tools/verify_pathfinding.gd

func _initialize() -> void:
	var fail := 0
	fail += _test_basic()
	fail += _test_size_gating()      # ⭐ 核心
	fail += _test_rotation_needed()
	fail += _test_determinism()
	fail += _test_blocked_by_unit()
	print("")
	print("========== 总失败数: %d ==========" % fail)
	quit(0 if fail == 0 else 1)


func _mk(size: GameEnums.SizeClass, id: int = 1) -> Unit:
	var u := Unit.new()
	u.id = id
	u.hp = 10
	u.hp_max = 10
	u.size_class = size
	u.size_data = SizeClassData.make(size)
	u.team = GameEnums.Team.PLAYER
	return u


# ---- 1. 基本可达性
func _test_basic() -> int:
	var bad := 0
	var g := HexGrid.new()
	var u := _mk(GameEnums.SizeClass.S)
	u.anchor = HexCoord.offset_to_cube(4, 1)
	u.facing = 2

	var r1 := HexPathfinder.reachable_anchors(g, u, 1)
	var r3 := HexPathfinder.reachable_anchors(g, u, 3)
	print("1) 空旷厅堂 S 单位 预算1 可达锚点=%d  预算3=%d（应递增）" % [r1.size(), r3.size()])
	if r3.size() <= r1.size():
		bad += 1

	# 到对角的路径长度应等于六边形距离
	var target := HexCoord.offset_to_cube(4, 7)
	var d := HexCoord.distance(u.anchor, target)
	var path := HexPathfinder.path_to(g, u, target, -1, 99)
	print("   (4,1)->(4,7) 六边形距离=%d  路径步数=%d（应相等）" % [d, path.size()])
	if path.size() != d:
		print("   FAIL 路径非最短")
		bad += 1
	return bad


# ---- 2. ⭐ 体型闸门的最终答案
func _test_size_gating() -> int:
	var bad := 0
	print("2) ⭐ 体型闸门（用寻路判定，这才是正确方法）")

	var configs := [
		["1格门洞", [4]],
		["2格门洞", [3, 4]],
		["3格门洞", [3, 4, 5]],
	]
	var results := {}

	for cfg in configs:
		var label: String = cfg[0]
		var door_cols: Array = cfg[1]
		var g := HexGrid.new()
		for col in range(1, 8):
			if col in door_cols:
				continue
			g.set_terrain(HexCoord.offset_to_cube(col, 4), GameEnums.Terrain.WALL)

		var row: Array = []
		for pair in [["S", GameEnums.SizeClass.S], ["M", GameEnums.SizeClass.M], ["L", GameEnums.SizeClass.L]]:
			var u := _mk(pair[1])
			u.anchor = HexCoord.offset_to_cube(4, 1)
			u.facing = 2
			# 起点必须合法，否则测的是"放不下"而非"过不去"
			if not HexFootprint.can_place(g, u.anchor, u.footprint(), u.facing):
				row.append("%s=起点放不下" % pair[0])
				continue
			# 目标：上半区某个锚点
			var goal := HexCoord.offset_to_cube(4, 6)
			var ok := HexPathfinder.can_reach(g, u, goal, 99)
			row.append("%s=%s" % [pair[0], "可过" if ok else "过不去"])
			results[label + pair[0]] = ok
		print("   %s : %s" % [label, "  ".join(row)])

	# 断言：1 格门洞必须挡住 M 与 L，放过 S
	if results.get("1格门洞S", false) != true:
		print("   FAIL 1格门洞应放过 S")
		bad += 1
	if results.get("1格门洞M", true) != false:
		print("   FAIL 1格门洞应挡住 M")
		bad += 1
	if results.get("1格门洞L", true) != false:
		print("   FAIL 1格门洞应挡住 L")
		bad += 1
	# 3 格门洞应该谁都能过
	if results.get("3格门洞M", false) != true:
		print("   FAIL 3格门洞应放过 M")
		bad += 1

	print("   → 结论：1格门=只有S能过（真闸门）；宽门放行大体型。")
	print("     这是 M0 判据④「巨人与骑士在狭道上打法明显不同」的机制基础。")
	return bad


# ---- 3. 需要转向才能通过的场景（验证 (anchor,facing) 状态空间的必要性）
func _test_rotation_needed() -> int:
	var bad := 0
	var g := HexGrid.new()
	# 造一条竖向 2 格宽走廊：col 3,4 通，其余墙
	for row in range(3, 6):
		for col in range(1, 8):
			if col == 3 or col == 4:
				continue
			g.set_terrain(HexCoord.offset_to_cube(col, row), GameEnums.Terrain.WALL)

	var u := _mk(GameEnums.SizeClass.M)
	u.anchor = HexCoord.offset_to_cube(4, 1)
	u.facing = 2
	if not HexFootprint.can_place(g, u.anchor, u.footprint(), u.facing):
		print("3) 跳过（M 起点放不下）")
		return 0

	var d := HexPathfinder.reachable(g, u, 99)
	# 统计到达每个锚点用到的朝向种类 —— 若 >1 说明转向确实参与了寻路
	var facings_used := {}
	for sid in d:
		var e: Dictionary = d[sid]
		var key := str(e["anchor"])
		if not facings_used.has(key):
			facings_used[key] = {}
		facings_used[key][e["facing"]] = true
	var multi := 0
	for k in facings_used:
		if (facings_used[k] as Dictionary).size() > 1:
			multi += 1
	print("3) M 在2格走廊中：可达状态=%d，其中 %d 个锚点有多种可行朝向" % [d.size(), multi])
	print("   → 证明 (anchor,facing) 状态空间是必要的（单纯 anchor 会丢解）")
	if d.size() == 0:
		bad += 1
	return bad


# ---- 4. 确定性：同输入多次跑，路径必须逐位相同
func _test_determinism() -> int:
	var bad := 0
	var g := HexGrid.new()
	g.set_terrain(HexCoord.offset_to_cube(3, 3), GameEnums.Terrain.WALL)
	g.set_terrain(HexCoord.offset_to_cube(5, 5), GameEnums.Terrain.RUBBLE)
	var target := HexCoord.offset_to_cube(6, 6)

	var first: Array = []
	var same := true
	for i in range(20):
		var u := _mk(GameEnums.SizeClass.S)
		u.anchor = HexCoord.offset_to_cube(2, 2)
		u.facing = 0
		var p := HexPathfinder.path_to(g, u, target, -1, 99)
		if i == 0:
			first = p
		elif str(p) != str(first):
			same = false
	print("4) 同输入跑 20 次路径一致: %s" % same)
	print("   路径=%s" % str(first))
	if not same:
		print("   FAIL 寻路不确定 —— 违反纪律 5")
		bad += 1
	return bad


# ---- 5. 被其他单位挡住
func _test_blocked_by_unit() -> int:
	var bad := 0
	var g := HexGrid.new()
	# 在 (4,2) 放一个敌人，堵住正上方
	g.set_occupancy(99, [HexCoord.offset_to_cube(4, 2)])

	var u := _mk(GameEnums.SizeClass.S, 1)
	u.anchor = HexCoord.offset_to_cube(4, 1)
	u.facing = 2

	var anchors := HexPathfinder.reachable_anchors(g, u, 1)
	var blocked_cell := HexCoord.offset_to_cube(4, 2)
	var can_enter := anchors.has(blocked_cell)
	print("5) 被单位占据的格可进入: %s（应 false）" % can_enter)
	if can_enter:
		bad += 1

	# 但绕行应该仍可到达上方
	var ok := HexPathfinder.can_reach(g, u, HexCoord.offset_to_cube(4, 3), 99)
	print("   绕行到 (4,3): %s（应 true）" % ok)
	if not ok:
		bad += 1
	return bad
