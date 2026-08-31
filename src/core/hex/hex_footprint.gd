class_name HexFootprint
## 体型占位校验的【唯一出口】—— D8 / 策划案 §14.2、§15.2
##
## ⚠️ R9（策划案 §16.1）：多格单位的边界情况极多（转向被卡、推拉部分重叠、
##    寻路、召唤位置），且"必须在 M0 就做，后期加体型系统的重构成本极高"。
##
## 因此：所有位移 / 生成 / 转向【必须】走 can_place()，
## 即使当前单位是 S 体型（footprint 长度恒为 1）。
## 不要写"如果是 S 就跳过检查"的快路径 —— 那正是 R9 说的重构陷阱。

## 把 footprint 按 facing 旋转后展开成绝对立方坐标集合。
##
## ⚠️ 这里用 HexCoord.rotate（策划案 §8.1 原文公式），已验证与 §8.2.4
##    的出生表一致：facing=2 时 M 占 (4,1)(3,2)(4,2)，朝上。
static func cells(anchor: Vector3i, footprint: Array[Vector3i], facing: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for off in footprint:
		out.append(anchor + HexCoord.rotate(off, facing))
	return out


## 校验一个单位能否放在 (anchor, facing)。
##
## 依次校验（§15.2 原文顺序）：
##   1. in_bounds  —— 所有格必须在 7×7 内
##   2. is_walkable —— 非 WALL / 非 PIT（除非会飞/可碾压）
##   3. occupant_at —— 未被其他单位占据（ignore_unit_id 用于自身移动/转向）
##
## ignore_unit_id：移动自己时要忽略自己当前占的格，否则原地转向永远失败。
static func can_place(
	grid: HexGrid,
	anchor: Vector3i,
	footprint: Array[Vector3i],
	facing: int,
	ignore_unit_id: int = -1,
	can_crush_rubble: bool = false
) -> bool:
	var target := cells(anchor, footprint, facing)
	for c in target:
		if not grid.in_bounds(c):
			return false
		if not grid.is_walkable(c, can_crush_rubble):
			return false
		var occ := grid.occupant_at(c)
		if occ != -1 and occ != ignore_unit_id:
			return false
	return true


## 校验结果的详细版本，用于 UI 提示与调试（告诉玩家"为什么放不下"）
static func place_failure_reason(
	grid: HexGrid,
	anchor: Vector3i,
	footprint: Array[Vector3i],
	facing: int,
	ignore_unit_id: int = -1,
	can_crush_rubble: bool = false
) -> String:
	var target := cells(anchor, footprint, facing)
	for c in target:
		var o := HexCoord.cube_to_offset(c)
		if not grid.in_bounds(c):
			return "格 (%d,%d) 超出战场" % [o.x, o.y]
		if not grid.is_walkable(c, can_crush_rubble):
			return "格 (%d,%d) 不可通行" % [o.x, o.y]
		var occ := grid.occupant_at(c)
		if occ != -1 and occ != ignore_unit_id:
			return "格 (%d,%d) 已被单位 #%d 占据" % [o.x, o.y, occ]
	return ""


## 单位占据格的相邻格集合（不含自身占格）。
## 用于 ADJACENT_ALL 目标形状、背击判定、"相邻敌人"类效果。
## ⚠️ 大体型的相邻格显著更多 —— 这是 §8.2.2 机制点 3 的直接后果。
static func adjacent_cells(
	anchor: Vector3i, footprint: Array[Vector3i], facing: int
) -> Array[Vector3i]:
	var own := cells(anchor, footprint, facing)
	var own_set := {}
	for c in own:
		own_set[c] = true
	var out: Array[Vector3i] = []
	var seen := {}
	for c in own:
		for d in HexCoord.DIRS:
			var n: Vector3i = c + d
			if own_set.has(n) or seen.has(n):
				continue
			seen[n] = true
			out.append(n)
	return out


## 从多格单位到目标格的距离 —— 取【最近的己方 footprint 格】起算。
## §8.2.2 机制点 3：大体型的"有效射程"更长。
static func distance_from(
	anchor: Vector3i, footprint: Array[Vector3i], facing: int, target: Vector3i
) -> int:
	var best := 9999
	for c in cells(anchor, footprint, facing):
		best = mini(best, HexCoord.distance(c, target))
	return best


## 求 footprint 的边界边集合，用于 Line2D 描边（§13.2 硬性要求）。
## 算法：把每格的 6 条边塞进字典计数，count==2 的是内部边（丢弃），
##       count==1 的组成边界。返回边的端点对数组（立方坐标的顶点索引形式）。
##
## 返回：Array[Array[Vector3i]]，每项是 [cell, dir_index] 表示"该格朝某方向的那条边"
static func boundary_edges(
	anchor: Vector3i, footprint: Array[Vector3i], facing: int
) -> Array:
	var own := cells(anchor, footprint, facing)
	var own_set := {}
	for c in own:
		own_set[c] = true
	var out: Array = []
	# 确定性顺序：按格的 (z, x) 排序后逐格、逐方向
	var sorted_cells := own.duplicate()
	sorted_cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.z != b.z:
			return a.z < b.z
		return a.x < b.x
	)
	for c in sorted_cells:
		for di in range(6):
			var n: Vector3i = c + HexCoord.DIRS[di]
			if not own_set.has(n):
				out.append([c, di])
	return out
