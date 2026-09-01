class_name TargetResolver
## TargetSpec → 格子集合 / 单位集合 —— §8.5
##
## ⚠️ 多格单位的两条特殊规则（§8.2.2）：
##   机制点 2：任意一格被范围覆盖即算命中，但【每次攻击只结算 1 次伤害】
##             （不因占多格而多次受伤）—— 所以返回的是【去重的单位集合】
##   机制点 3：射程从【最近的己方 footprint 格】起算 —— 大体型有效射程更长


## 合法目标格集合（UI 高亮"可打哪里"）
static func legal_cells(state, caster: Unit, spec: TargetSpec) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if spec == null:
		return out
	if spec.shape == GameEnums.TargetShape.SELF:
		out.append(caster.anchor)
		return out

	# ⚠️ 遍历 grid.all_cells()（按 row,col 固定顺序）保证确定性
	for c in state.grid.all_cells():
		var d := caster.distance_to_cell(c)   # 机制点 3：最近己方格起算
		if d < spec.range_min or d > spec.range_max:
			continue
		if spec.requires_line_of_sight and not _has_los_from_unit(state, caster, c):
			continue

		if spec.shape == GameEnums.TargetShape.TILE:
			# TILE = 指向格子（移动/传送）。落点必须能【放下施法者的整个 footprint】，
			# 否则 M/L 单位会看到一堆点不了的"合法"格。忽略自身占格。
			if not HexFootprint.can_place(state.grid, c, caster.footprint(),
					caster.facing, caster.id, caster.can_crush_rubble()):
				continue
			out.append(c)
			continue

		if not spec.can_target_empty_cell:
			var occ: Unit = state.unit_at(c)
			if occ == null or not occ.is_alive:
				continue
			if not _team_allowed(spec, caster, occ):
				continue
		out.append(c)
	return out


## 多格单位的视线：任一 footprint 格对目标有视线即算有（§8.2.2 引申）
static func _has_los_from_unit(state, caster: Unit, target: Vector3i) -> bool:
	for own in caster.cells():
		if state.grid.has_line_of_sight(own, target):
			return true
	return false


static func _team_allowed(spec: TargetSpec, caster: Unit, target: Unit) -> bool:
	if spec.valid_teams.is_empty():
		# 默认：敌对目标
		return caster.is_hostile_to(target)
	return int(target.team) in spec.valid_teams


## 给定选定格，求实际波及的【单位集合】（去重 —— 机制点 2）
##
## ⚠️ 这里曾漏掉队伍过滤，造成一个很隐蔽的 bug：
##   LINE 形状从 caster.anchor 起算，而 M/L 玩家【自身的 footprint 格就在线上】
##   → 《穿刺投枪》扎自己。实测巨人 vs enc_04 在敌人零次攻击的回合掉 17 血
##     （投枪 11 + 冲撞 4），20/20 全败其实是自杀，不是被 Boss 打死。
##   骑士（S 体型，footprint=1）因为 cells_in_line 从 anchor+d 起算跳过了自己，
##   侥幸没暴露 —— 这类"小体型偶然正确"的 bug 最难发现。
##
##   已确认的规则：**完全禁止友伤**。AOE/直线一律只打敌对单位。
static func affected_units(state, caster: Unit, spec: TargetSpec, chosen: Vector3i) -> Array[Unit]:
	var cells := affected_cells(state, caster, spec, chosen)
	var seen := {}
	var out: Array[Unit] = []
	for c in cells:
		var u: Unit = state.unit_at(c)
		if u == null or not u.is_alive:
			continue
		if seen.has(u.id):
			continue
		# 队伍过滤：只打敌对单位。自己与友方一律跳过。
		if u.id == caster.id or not caster.is_hostile_to(u):
			continue
		seen[u.id] = true
		out.append(u)
	# 确定性：按 id 排序
	out.sort_custom(func(a: Unit, b: Unit) -> bool: return a.id < b.id)
	return out


## 波及格集合（UI 高亮"会打到哪些格"）
static func affected_cells(state, caster: Unit, spec: TargetSpec, chosen: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if spec == null:
		return out

	match spec.shape:
		GameEnums.TargetShape.SELF:
			for c in caster.cells():
				out.append(c)

		GameEnums.TargetShape.SINGLE, GameEnums.TargetShape.TILE:
			out.append(chosen)

		GameEnums.TargetShape.LINE:
			var di := _dir_index_towards(caster.anchor, chosen)
			var n := spec.area_size if spec.area_size > 0 else spec.range_max
			# ⚠️ 排除施法者自身占格：M/L 体型的 footprint 会落在这条线上，
			#    否则 UI 会把"打到自己"高亮出来（伤害侧已在 affected_units 过滤）
			var own := _own_cells_set(caster)
			for c in state.grid.cells_in_line(caster.anchor, di, n):
				if own.has(c):
					continue
				out.append(c)

		GameEnums.TargetShape.BURST:
			for c in state.grid.cells_in_range(chosen, spec.area_size):
				out.append(c)

		GameEnums.TargetShape.RING:
			for c in state.grid.cells_in_ring(chosen, maxi(1, spec.area_size)):
				out.append(c)

		GameEnums.TargetShape.CONE:
			var di2 := _dir_index_towards(caster.anchor, chosen)
			var own2 := _own_cells_set(caster)
			for c in _cone_cells(state, caster.anchor, di2, maxi(1, spec.area_size)):
				if own2.has(c):
					continue
				out.append(c)

		GameEnums.TargetShape.ADJACENT_ALL:
			# ⚠️ 大体型的相邻格显著更多 —— 这是体型的收益面（机制点 3 引申）
			for c in caster.adjacent_cells():
				out.append(c)

	return out


## 施法者自身占格的集合（用于 LINE/CONE 排除自己）
static func _own_cells_set(caster: Unit) -> Dictionary:
	var out := {}
	for c in caster.cells():
		out[c] = true
	return out


## 求 from → to 的主方向索引（用于 LINE / CONE）
static func _dir_index_towards(from: Vector3i, to: Vector3i) -> int:
	var delta := to - from
	var best := 0
	var best_dot := -999999
	for i in range(6):
		var d := HexCoord.DIRS[i]
		var dot := delta.x * d.x + delta.y * d.y + delta.z * d.z
		if dot > best_dot:
			best_dot = dot
			best = i
	return best


static func _cone_cells(state, origin: Vector3i, dir_index: int, length: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var seen := {}
	# 锥形 = 主方向 + 两侧各展开一格，逐层加宽
	for step in range(1, length + 1):
		for spread in range(-step + 1, step):
			var d1 := HexCoord.DIRS[posmod(dir_index, 6)]
			var d2 := HexCoord.DIRS[posmod(dir_index + (1 if spread > 0 else -1), 6)]
			var c: Vector3i = origin + d1 * step + d2 * absi(spread)
			if not state.grid.in_bounds(c) or seen.has(c):
				continue
			seen[c] = true
			out.append(c)
	return out


## 是否可对某单位施放（含体型过滤）
static func can_target_unit(spec: TargetSpec, caster: Unit, target: Unit) -> bool:
	if spec == null or target == null or not target.is_alive:
		return false
	if not spec.valid_size_classes.is_empty():
		if not int(target.size_class) in spec.valid_size_classes:
			return false
	return _team_allowed(spec, caster, target)
