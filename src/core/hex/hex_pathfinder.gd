class_name HexPathfinder
## 多格单位寻路 —— §14.1 hex_pathfinder.gd
##
## ⚠️ 状态是 (anchor, facing) 而【不是】anchor ——
##    因为 M/L 转向会改变占位（§8.2.2 机制点 5），
##    "能不能走到那里"可能取决于"到那里时朝哪边"。
##    状态数 49×6 = 294，Dijkstra 秒开。
##
## ⚠️ 这里也是"体型能否通过狭道"的【正确判定处】。
##    footprint 层只能判单点合法性，通过性必须搜索 —— 我在 verify_footprint
##    里连续用 4 种静态几何判据都失败，教训写在那个文件的注释里。
##
## 确定性（纪律 5）：
##   · 优先队列比较键 = (cost, state_id)，state_id = anchor_index*6 + facing
##   · 邻居枚举顺序固定为 [平移 0..5, 旋转 +1, 旋转 -1]
##   禁止用无 tiebreak 的堆 —— 同代价路径的选择必须可复现。


## 把 (anchor, facing) 编码成整数，用于确定性排序与字典键
static func state_id(anchor: Vector3i, facing: int) -> int:
	var o := HexCoord.cube_to_offset(anchor)
	var idx := (o.y - 1) * HexCoord.COLS + (o.x - 1)
	return idx * 6 + posmod(facing, 6)


static func decode_state(sid: int) -> Array:
	var facing := sid % 6
	var idx := sid / 6
	var col := idx % HexCoord.COLS + 1
	var row := idx / HexCoord.COLS + 1
	return [HexCoord.offset_to_cube(col, row), facing]


## 计算可达状态集。
##
## 返回 Dictionary[state_id] -> {cost:int, prev:int, anchor:Vector3i, facing:int}
static func reachable(
	grid: HexGrid, unit: Unit, budget: int, state = null
) -> Dictionary:
	var foot := unit.footprint()
	var crush := unit.can_crush_rubble()
	var rot_cost := unit.rotate_cost()
	var move_delta := RuleBook.move_cost_delta(state) if state != null else 0

	var start_id := state_id(unit.anchor, unit.facing)
	var dist := {start_id: {"cost": 0, "prev": -1, "anchor": unit.anchor, "facing": unit.facing}}

	# 简单的有序 frontier（294 个状态，无需真正的堆）
	var frontier: Array[int] = [start_id]

	while not frontier.is_empty():
		# 取 cost 最小、id 最小者（确定性 tiebreak）
		frontier.sort_custom(func(a: int, b: int) -> bool:
			var ca: int = dist[a]["cost"]
			var cb: int = dist[b]["cost"]
			if ca != cb:
				return ca < cb
			return a < b
		)
		var cur_id: int = frontier.pop_front()
		var cur: Dictionary = dist[cur_id]
		var cur_cost: int = cur["cost"]
		if cur_cost >= budget:
			continue

		var cur_anchor: Vector3i = cur["anchor"]
		var cur_facing: int = cur["facing"]

		# --- 邻居 1: 6 个平移（facing 不变）。顺序固定 0..5
		for di in range(6):
			var next_anchor: Vector3i = cur_anchor + HexCoord.DIRS[di]
			if not HexFootprint.can_place(grid, next_anchor, foot, cur_facing, unit.id, crush):
				continue
			var step := grid.move_cost_at(next_anchor, crush) + move_delta
			step = maxi(1, step)
			var nc := cur_cost + step
			if nc > budget:
				continue
			var nid := state_id(next_anchor, cur_facing)
			if not dist.has(nid) or nc < dist[nid]["cost"]:
				dist[nid] = {"cost": nc, "prev": cur_id, "anchor": next_anchor, "facing": cur_facing}
				frontier.append(nid)

		# --- 邻居 2: 原地旋转 ±1（顺序固定 +1 然后 -1）
		for delta in [1, -1]:
			var nf := posmod(cur_facing + delta, 6)
			# ⚠️ 多格单位转向会改变占位，必须校验（机制点 5）
			if not HexFootprint.can_place(grid, cur_anchor, foot, nf, unit.id, crush):
				continue
			var nc2 := cur_cost + maxi(0, rot_cost)
			if nc2 > budget:
				continue
			var nid2 := state_id(cur_anchor, nf)
			if not dist.has(nid2) or nc2 < dist[nid2]["cost"]:
				dist[nid2] = {"cost": nc2, "prev": cur_id, "anchor": cur_anchor, "facing": nf}
				frontier.append(nid2)

	return dist


## 可达的【锚点】集合（UI 高亮用）。同一锚点取最小 cost。
static func reachable_anchors(
	grid: HexGrid, unit: Unit, budget: int, state = null
) -> Dictionary:
	var d := reachable(grid, unit, budget, state)
	var out := {}
	# 按 state_id 升序遍历，保证同 cost 时结果确定
	var ids: Array = d.keys()
	ids.sort()
	for sid in ids:
		var e: Dictionary = d[sid]
		var a: Vector3i = e["anchor"]
		if not out.has(a) or e["cost"] < out[a]["cost"]:
			out[a] = {"cost": e["cost"], "facing": e["facing"], "sid": sid}
	return out


## 求到目标状态的路径。返回 offset 坐标数组（可序列化，直接喂 Actions.move）。
## target_facing < 0 表示任意朝向（取代价最小者）。
static func path_to(
	grid: HexGrid, unit: Unit, target_anchor: Vector3i,
	target_facing: int = -1, budget: int = 99, state = null
) -> Array:
	var d := reachable(grid, unit, budget, state)

	var best_id := -1
	var best_cost := 1 << 30
	var candidate_ids: Array = d.keys()
	candidate_ids.sort()   # 确定性
	for sid in candidate_ids:
		var e: Dictionary = d[sid]
		if e["anchor"] != target_anchor:
			continue
		if target_facing >= 0 and e["facing"] != target_facing:
			continue
		if e["cost"] < best_cost:
			best_cost = e["cost"]
			best_id = sid

	if best_id < 0:
		return []

	# 回溯。
	# ⚠️ 只保留【锚点发生变化】的节点 —— 状态图里"原地旋转"也是一条边，
	#    若把它也算进路径，S 单位（rotate_cost=0）会出现
	#    "距离 6 却走 8 步"这种虚假绕路（实测踩过）。
	#    朝向变化通过 Actions.move 的 facing 参数一次性传达，不占路径步。
	var chain: Array = []
	var cur := best_id
	var prev_anchor := Vector3i(9999, 9999, 9999)
	while cur != -1:
		var e: Dictionary = d[cur]
		var a: Vector3i = e["anchor"]
		if a != prev_anchor:
			var o := HexCoord.cube_to_offset(a)
			chain.append([o.x, o.y])
			prev_anchor = a
		cur = e["prev"]
	chain.reverse()
	# 去掉起点，只留移动步
	if chain.size() > 1:
		chain.remove_at(0)
	return chain


## 到达目标锚点时的最优朝向（配合 path_to 用）
static func best_facing_at(
	grid: HexGrid, unit: Unit, target_anchor: Vector3i, budget: int = 99, state = null
) -> int:
	var d := reachable(grid, unit, budget, state)
	var best_f := -1
	var best_cost := 1 << 30
	var ids: Array = d.keys()
	ids.sort()
	for sid in ids:
		var e: Dictionary = d[sid]
		if e["anchor"] == target_anchor and e["cost"] < best_cost:
			best_cost = e["cost"]
			best_f = e["facing"]
	return best_f


## ⭐ 通过性判定：unit 能否从 from_anchor 走到 to_anchor（任意朝向）。
## 这是"体型能否通过狭道"的正确答案 —— 见文件头注释。
static func can_reach(
	grid: HexGrid, unit: Unit, to_anchor: Vector3i, budget: int = 99, state = null
) -> bool:
	var d := reachable(grid, unit, budget, state)
	for sid in d:
		if d[sid]["anchor"] == to_anchor:
			return true
	return false
