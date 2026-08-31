class_name EnemyAI
## 敌人意图决策 —— §8.7 / §14.1 enemy_ai.gd
##
## ⚠️ 意图必须在生成时【冻结全部结算参数】（目标格集合、伤害包），
##    执行阶段只重放。否则"打空型 vs 追踪型"的区分做不出来 ——
##    而§13.2 明确要求玩家能读出「意图是否可躲」，这是核心决策信息。
##
##   FIXED_TILE   锁定格子：玩家走开则打空（可躲）
##   TRACK_TARGET 锁定单位：跟着玩家走（躲不掉）


## 为一个敌人生成下回合意图（纯数据，可序列化）
static func decide(state, enemy: Unit) -> Dictionary:
	var player: Unit = state.player()
	if player == null or not player.is_alive:
		return {"kind": int(GameEnums.IntentKind.SLEEP)}

	var dist := enemy.distance_to_unit(player)

	match enemy.ai_profile:
		GameEnums.AIProfile.RANGED_KITER:
			return _decide_ranged(state, enemy, player, dist)
		GameEnums.AIProfile.BLOCKER:
			return _decide_blocker(state, enemy, player, dist)
		_:
			return _decide_melee(state, enemy, player, dist)


## 近战：不相邻则移动靠近，相邻则攻击
static func _decide_melee(state, enemy: Unit, player: Unit, dist: int) -> Dictionary:
	if dist <= 1:
		return _make_attack(state, enemy, player)
	var step := _step_towards(state, enemy, player)
	if step.is_empty():
		return {"kind": int(GameEnums.IntentKind.SLEEP), "reason": "unreachable"}
	return {
		"kind": int(GameEnums.IntentKind.MOVE),
		"path": [step],
		"facing": _facing_towards(enemy.anchor, player.anchor),
	}


## 求朝玩家靠近的一步（offset 形式）。
##
## ⚠️ 不能直接 path_to(player.anchor) —— 那一格被玩家占着，
##    can_place 会正确地拒绝，导致寻路永远返回空、敌人永远 SLEEP(unreachable)。
##    正解：以玩家【相邻格】为目标，取其中可达且总代价最小者。
static func _step_towards(state, enemy: Unit, player: Unit) -> Array:
	var goals := player.adjacent_cells()
	# 确定性：按 (row, col) 排序
	goals.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var oa := HexCoord.cube_to_offset(a)
		var ob := HexCoord.cube_to_offset(b)
		if oa.y != ob.y:
			return oa.y < ob.y
		return oa.x < ob.x
	)
	var best_path: Array = []
	var best_len := 1 << 30
	for g in goals:
		if not state.grid.is_walkable(g):
			continue
		var p := HexPathfinder.path_to(state.grid, enemy, g, -1, 99, state)
		if p.is_empty():
			continue
		if p.size() < best_len:
			best_len = p.size()
			best_path = p
	if best_path.is_empty():
		return []
	return best_path[0]


## 远程风筝：太近则后退，射程内则攻击
static func _decide_ranged(state, enemy: Unit, player: Unit, dist: int) -> Dictionary:
	if dist <= 1:
		# 后退一格
		var away := _dir_away(enemy.anchor, player.anchor)
		var back: Vector3i = enemy.anchor + HexCoord.DIRS[away]
		if HexFootprint.can_place(state.grid, back, enemy.footprint(), enemy.facing, enemy.id):
			var o := HexCoord.cube_to_offset(back)
			return {"kind": int(GameEnums.IntentKind.MOVE), "path": [[o.x, o.y]],
					"facing": _facing_towards(back, player.anchor)}
	if dist <= 3 and _has_los(state, enemy, player):
		return _make_attack(state, enemy, player)
	# 靠近到射程内
	var step := _step_towards(state, enemy, player)
	if step.is_empty():
		return {"kind": int(GameEnums.IntentKind.SLEEP), "reason": "unreachable"}
	return {"kind": int(GameEnums.IntentKind.MOVE), "path": [step],
			"facing": _facing_towards(enemy.anchor, player.anchor)}


## 堵路型：贴身时攻击相邻全体；远离时缓慢逼近。
##
## ⚠️ 早期版本写成"不相邻就原地不动"，结果它永远不参战 ——
##    玩家不主动靠近就永远打不完（实测 20 场全部超时）。
##    BLOCKER 的设计意图是"难以绕过"，不是"完全静止"。
static func _decide_blocker(state, enemy: Unit, player: Unit, dist: int) -> Dictionary:
	if dist <= 1:
		var d := _make_attack(state, enemy, player)
		d["kind"] = int(GameEnums.IntentKind.MULTI_ATTACK)
		# ADJACENT_ALL：大体型相邻格更多 → 覆盖面更大
		var cells: Array = []
		for c in enemy.adjacent_cells():
			var o := HexCoord.cube_to_offset(c)
			cells.append([o.x, o.y])
		d["cells"] = cells
		return d
	# 逼近（比近战慢：只在距离 >2 时才移动，保留"守住阵地"的质感）
	var step := _step_towards(state, enemy, player)
	if step.is_empty():
		return {"kind": int(GameEnums.IntentKind.SLEEP), "reason": "unreachable"}
	return {
		"kind": int(GameEnums.IntentKind.MOVE),
		"path": [step],
		"facing": _facing_towards(enemy.anchor, player.anchor),
	}


## 生成攻击意图，并【冻结】目标信息
static func _make_attack(state, enemy: Unit, player: Unit) -> Dictionary:
	var ctx := DamageCalculator.Context.new()
	ctx.source = enemy
	ctx.target = player
	ctx.stat_ref = "ATK"
	ctx.stat_ratio = 1.0
	# 预览值（不消耗 RNG）——用于 UI 显示"预计伤害"
	var pv := DamageCalculator.preview(ctx)

	var d := {
		"kind": int(GameEnums.IntentKind.ATTACK),
		"targeting": int(enemy.intent_targeting),
		"preview_min": pv.x,
		"preview_max": pv.y,
		"facing": _facing_towards(enemy.anchor, player.anchor),
	}

	if enemy.intent_targeting == GameEnums.IntentTargeting.FIXED_TILE:
		# ⚠️ 冻结【格子】——玩家走开就打空（可躲）
		var cells: Array = []
		for c in player.cells():
			var o := HexCoord.cube_to_offset(c)
			cells.append([o.x, o.y])
		d["cells"] = cells
		d["dodgeable"] = true
	else:
		# 冻结【单位 id】——跟着玩家走（躲不掉）
		d["target_unit"] = player.id
		d["dodgeable"] = false
	return d


## 执行已预告的意图 —— 只重放，不重新决策
static func execute_intent(state, enemy: Unit, q: ActionQueue) -> void:
	var intent: Dictionary = enemy.intent
	if intent.is_empty():
		return
	var kind: int = intent.get("kind", int(GameEnums.IntentKind.SLEEP))

	match kind:
		int(GameEnums.IntentKind.MOVE):
			var path: Array = intent.get("path", [])
			if not path.is_empty():
				q.push_back(Actions.move(enemy.id, path, intent.get("facing", -1), "enemy_ai"))

		int(GameEnums.IntentKind.ATTACK), int(GameEnums.IntentKind.MULTI_ATTACK):
			var targets := _resolve_intent_targets(state, intent)
			for t in targets:
				var ctx := DamageCalculator.Context.new()
				ctx.source = enemy
				ctx.target = t
				ctx.stat_ref = "ATK"
				ctx.stat_ratio = 1.0
				# 背击判定：攻击者是否在目标后弧
				ctx.from_rear = t.is_attacked_from_rear(enemy.anchor)
				var r := DamageCalculator.calculate(ctx, state.rng)
				q.push_back(Actions.damage(enemy.id, t.id, r.to_dict(), "enemy_ai"))
			if targets.is_empty():
				state.log_event("intent_missed", {"unit": enemy.id, "reason": "打空"})

		_:
			pass


## 按冻结的意图求实际命中的单位
static func _resolve_intent_targets(state, intent: Dictionary) -> Array[Unit]:
	var out: Array[Unit] = []
	if intent.has("target_unit"):
		# 追踪型：直接锁单位
		var u: Unit = state.unit_by_id(intent["target_unit"])
		if u != null and u.is_alive:
			out.append(u)
		return out
	# 打空型：看冻结的格子上现在有谁
	var seen := {}
	for cell in intent.get("cells", []):
		var c := HexCoord.offset_to_cube(cell[0], cell[1])
		var u: Unit = state.unit_at(c)
		if u == null or not u.is_alive or seen.has(u.id):
			continue
		seen[u.id] = true
		out.append(u)
	out.sort_custom(func(a: Unit, b: Unit) -> bool: return a.id < b.id)
	return out


static func _facing_towards(from: Vector3i, to: Vector3i) -> int:
	var delta := to - from
	var best_f := 0
	var best_dot := -999999
	for f in range(6):
		var d := HexCoord.facing_dir(f)   # ⚠️ 走 facing_dir，不用 DIRS[f]（陷阱 H1）
		var dot := delta.x * d.x + delta.y * d.y + delta.z * d.z
		if dot > best_dot:
			best_dot = dot
			best_f = f
	return best_f


static func _dir_away(from: Vector3i, threat: Vector3i) -> int:
	var delta := from - threat
	var best := 0
	var best_dot := -999999
	for i in range(6):
		var d := HexCoord.DIRS[i]
		var dot := delta.x * d.x + delta.y * d.y + delta.z * d.z
		if dot > best_dot:
			best_dot = dot
			best = i
	return best


static func _has_los(state, a: Unit, b: Unit) -> bool:
	for ca in a.cells():
		for cb in b.cells():
			if state.grid.has_line_of_sight(ca, cb):
				return true
	return false
