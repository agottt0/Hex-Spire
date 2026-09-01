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
		GameEnums.AIProfile.BOSS_PHASED:
			return _decide_boss(state, enemy, player, dist)
		_:
			return _decide_melee(state, enemy, player, dist)


## Boss：按 HP 百分比切换阶段（§8.7 的 BOSS_PHASED）。
##
## ⚠️ 这个分支曾【完全缺失】—— `match` 没有 BOSS_PHASED case，
##    于是静默 fallthrough 到 _decide_melee，攻城虫和扑咬犬用同一套 AI。
##    数据里标了 profile 而代码忽略 = 数据/代码不一致，属于 bug。
##
## 三个阶段（HP 阈值取自策划案 §15.8 boss_phases 的形态）：
##   阶段1 (>50%)  常规近战
##   阶段2 (25-50%) 更激进：优先走到能同时覆盖多格的位置，用 MULTI_ATTACK
##   阶段3 (<25%)  狂暴：每回合都攻击，移动力 +1
static func boss_phase(enemy: Unit) -> int:
	var ratio := float(enemy.hp) / float(maxi(1, enemy.hp_max))
	if ratio > 0.5:
		return 1
	if ratio > 0.25:
		return 2
	return 3


static func _decide_boss(state, enemy: Unit, player: Unit, dist: int) -> Dictionary:
	var phase := boss_phase(enemy)

	if dist <= 1:
		var d := _make_attack(state, enemy, player)
		if phase >= 2:
			# 阶段2+：范围攻击，覆盖自身全部相邻格（大体型相邻格多 → 很难躲）
			d["kind"] = int(GameEnums.IntentKind.MULTI_ATTACK)
			var cells: Array = []
			for c in enemy.adjacent_cells():
				var o := HexCoord.cube_to_offset(c)
				cells.append([o.x, o.y])
			d["cells"] = cells
		d["phase"] = phase
		return d

	# 阶段3 狂暴：移动力 +1
	var budget := move_budget(enemy) + (1 if phase == 3 else 0)
	var path := _move_path(state, enemy, player, budget)
	if path.is_empty():
		return {"kind": int(GameEnums.IntentKind.SLEEP), "reason": "unreachable", "phase": phase}
	return {
		"kind": int(GameEnums.IntentKind.MOVE),
		"path": path,
		"facing": _facing_towards(enemy.anchor, player.anchor),
		"phase": phase,
	}


## 近战：不相邻则移动靠近，相邻则攻击
static func _decide_melee(state, enemy: Unit, player: Unit, dist: int) -> Dictionary:
	if dist <= 1:
		return _make_attack(state, enemy, player)
	var path := _move_path(state, enemy, player, move_budget(enemy))
	if path.is_empty():
		return {"kind": int(GameEnums.IntentKind.SLEEP), "reason": "unreachable"}
	return {
		"kind": int(GameEnums.IntentKind.MOVE),
		"path": path,
		"facing": _facing_towards(enemy.anchor, player.anchor),
	}


## 求朝玩家移动的路径（offset 数组形式，最多 max_steps 步）。
##
## ⚠️⚠️ 这个函数曾有两个 bug，都是实测才发现的，改前务必读完：
##
## 【Bug A：把 target_anchor 当成"贴身位置"】
##   旧写法 `path_to(grid, enemy, player.adjacent_cells()[i])` 是在问
##   「能不能把我的【锚点】放到玩家的邻格上」。
##   对 S 体型（footprint = 1 格）"锚点在邻格" ⟺ "身体贴着玩家"，语义偶然等价。
##   对 M/L 体型则两重失败：
##     ① 锚点紧贴玩家时，3/6 格身体必然与玩家重叠或撞墙 → can_place 失败
##     ② 即便成功，L 的锚点是三角形【尖端】、身体向后铺 2 格
##        → 质心离玩家 2–3 格，而攻击门槛是 dist <= 1，永远不触发
##   实测：narrow_pass 下 L 体型 Boss `SLEEP(unreachable)` 100%，直到 50 回合超时。
##
##   ✓ 正解：直接在 (anchor, facing) 状态图上搜索，筛出真正满足
##     `distance_to_unit(player) <= 1` 的状态 —— 也就是"身体贴到玩家"，
##     而不是"锚点落在某格"。HexPathfinder.reachable() 已返回全部 294 个状态。
##
## 【Bug B：每回合只走 1 格】
##   旧写法 `return best_path[0]` 只取第一步，而玩家一回合能走 7 格
##   （移动2 + 疾风步2 + 冲撞3）→ 7:1 速度差 → 玩家可以无限风筝。
##   实测：enc_02 理论输出 17 点/回合，实际玩家掉 0 血 —— 敌人根本没追上。
##   ✓ 正解：按 AGI 给出每回合移动力，一次走多步。
static func _path_towards(state, enemy: Unit, player: Unit, max_steps: int) -> Array:
	var reach: Dictionary = HexPathfinder.reachable(state.grid, enemy, max_steps, state)

	# 在可达状态里找"能贴到玩家"的，取 cost 最小；同 cost 用 state_id 保证确定性
	var best_sid := -1
	var best_cost := 1 << 30
	var best_dist := 1 << 30
	var ids: Array = reach.keys()
	ids.sort()
	for sid in ids:
		var e: Dictionary = reach[sid]
		var anchor: Vector3i = e["anchor"]
		var facing: int = e["facing"]
		# 用该状态下的实际占格算与玩家的距离（这才是"贴身"的正确判据）
		var d := 1 << 30
		for c in HexFootprint.cells(anchor, enemy.footprint(), facing):
			for pc in player.cells():
				d = mini(d, HexCoord.distance(c, pc))
		var cost: int = e["cost"]
		# 优先"更贴近"，其次"代价更小"
		if d < best_dist or (d == best_dist and cost < best_cost):
			best_dist = d
			best_cost = cost
			best_sid = sid

	if best_sid < 0:
		return []
	var target: Dictionary = reach[best_sid]
	# 已经在最佳位置（这一步预算内贴不了更近）→ 不需要移动
	if target["anchor"] == enemy.anchor and target["facing"] == enemy.facing:
		return []
	return HexPathfinder.path_to(
		state.grid, enemy, target["anchor"], target["facing"], max_steps, state)


## 移动路径的统一出口：先尝试贴身，贴不到就兜底逼近。
## 四个 decide 分支都走这里，保证【永远不产生僵局】。
##
## ⚠️ budget 内贴不到玩家时，不能只在 budget 范围里找"最近位置" ——
##   那会把单位锁在【局部最优】。实测：石傀(M) 卡在 (1,6) 不动 6 个回合，
##   因为它 3 格移动力内的所有位置都不比原地更近（门在 row 4，玩家在 row 3，
##   而穿门需要先绕到门口，前几步反而"变远"）。
##   正解：兜底时用【完整寻路】（budget=99）算出通往玩家的整条路，
##   然后只走 budget 步 —— 这样它会朝正确方向前进，即使前几步看起来变远。
static func _move_path(state, enemy: Unit, player: Unit, budget: int) -> Array:
	var p := _path_towards(state, enemy, player, budget)
	if not p.is_empty():
		return p
	# 用不限预算的寻路找"真正通往玩家"的路，再截取 budget 步
	var full := _path_towards(state, enemy, player, 99)
	if not full.is_empty():
		return full.slice(0, mini(budget, full.size()))
	return _fallback_approach(state, enemy, player, budget)


## 走不到玩家身边时的兜底：至少朝玩家方向挪，别站着不动。
##
## ⚠️ 为什么需要这个：地形可能把敌人和玩家【永久隔开】。
##   实测 narrow_pass + 攻城虫(L)：2 格门洞放得下它，但它跨不过 row 4
##   （这是体型闸门的正确行为，见 verify_pathfinding.gd 的三级门宽表）。
##   若此时返回 SLEEP，敌人会站到 50 回合超时 —— 战斗永远打不完。
##   兜底策略：在可达范围内选"离玩家最近"的位置，制造压迫感而非僵局。
##   真正的解法是关卡配置层（§9.7 模板校验器应校验"Boss 可达玩家"），
##   但 AI 侧也不该产生僵局。
static func _fallback_approach(state, enemy: Unit, player: Unit, max_steps: int) -> Array:
	var reach: Dictionary = HexPathfinder.reachable(state.grid, enemy, max_steps, state)
	var best_sid := -1
	var best_key := Vector2i(1 << 30, 1 << 30)
	var ids: Array = reach.keys()
	ids.sort()
	for sid in ids:
		var e: Dictionary = reach[sid]
		if e["anchor"] == enemy.anchor and e["facing"] == enemy.facing:
			continue
		# 用锚点到玩家锚点的直线距离排序（够用且确定）
		var d := HexCoord.distance(e["anchor"], player.anchor)
		var key := Vector2i(d, e["cost"])
		if key.x < best_key.x or (key.x == best_key.x and key.y < best_key.y):
			best_key = key
			best_sid = sid
	if best_sid < 0:
		return []
	var t: Dictionary = reach[best_sid]
	return HexPathfinder.path_to(state.grid, enemy, t["anchor"], t["facing"], max_steps, state)


## 敌人每回合的移动力。AGI 越高走越多（§4.3：AGI 的次要作用之一是移动）。
## 基础 2 格，每 K_AGI_PER_STEP 点 AGI +1，上限 4 —— 让敌人追得上但不至于秒近身。
static func move_budget(enemy: Unit) -> int:
	return clampi(2 + enemy.agi / K.K_AGI_PER_STEP, 2, 4)


## 兼容旧调用：只要第一步
static func _step_towards(state, enemy: Unit, player: Unit) -> Array:
	var p := _path_towards(state, enemy, player, move_budget(enemy))
	if p.is_empty():
		return []
	return p[0]


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
	var path := _move_path(state, enemy, player, move_budget(enemy))
	if path.is_empty():
		return {"kind": int(GameEnums.IntentKind.SLEEP), "reason": "unreachable"}
	return {"kind": int(GameEnums.IntentKind.MOVE), "path": path,
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
	# 逼近。BLOCKER 移动力比近战低 1（保留"守住阵地"的质感，但不至于永不参战）
	var path := _move_path(state, enemy, player, maxi(1, move_budget(enemy) - 1))
	if path.is_empty():
		return {"kind": int(GameEnums.IntentKind.SLEEP), "reason": "unreachable"}
	return {
		"kind": int(GameEnums.IntentKind.MOVE),
		"path": path,
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

	# ⚠️ 「可躲」的门槛设计（这是"硬但公平"的核心平衡点，改前读完）：
	#
	#   §8.7 原文：「近战敌人 = 打空（可被走位躲开）」，但也允许
	#   「按明示规则重定向 —— 规则必须固定且写在敌人图鉴里」。
	#
	#   纯粹锁定玩家当前占格的话，玩家打一张位移卡就 100% 免疫。
	#   实测：骑士有 3 张位移卡（移动/疾风步/冲撞），每回合都能躲 → 全程 0 掉血。
	#   §8.7 的设计意图是「走位是一种有效应对」，不是「走位无条件免疫」。
	#
	#   所以采用【明示的两段规则】：
	#     · 贴身（dist <= 1）的近战 → 转为 TRACK（咬住了，躲不掉）
	#     · 远处扑击 → FIXED_TILE，锁定玩家占格 + 朝向侧的相邻格（挥击有范围）
	#   玩家的应对从"随便走一步"变成"要么走远、要么先解决贴身的敌人"。
	#
	#   ⚠️ 判据用 `<= 1` 而不是更大的值：贴身才算"咬住"。
	#   若把 2 格也算追踪，远程与近战的区分就没了，玩家失去"拉开距离"这个应对。
	var melee_locked := enemy.distance_to_unit(player) <= 1 \
			and enemy.intent_targeting == GameEnums.IntentTargeting.FIXED_TILE

	if enemy.intent_targeting == GameEnums.IntentTargeting.TRACK_TARGET or melee_locked:
		# 追踪：冻结【单位 id】，跟着玩家走
		d["target_unit"] = player.id
		d["dodgeable"] = false
		if melee_locked:
			d["lock_reason"] = "已被咬住"
		return d

	# 打空型：冻结【格子】，玩家走出范围即落空
	var cells: Array = []
	var seen := {}
	for c in player.cells():
		var o := HexCoord.cube_to_offset(c)
		var key := "%d,%d" % [o.x, o.y]
		if not seen.has(key):
			seen[key] = true
			cells.append([o.x, o.y])
	# 朝向玩家的那一侧展开：挥击覆盖 3 个方向
	var toward := _facing_towards(enemy.anchor, player.anchor)
	var side_dirs := [
		HexCoord.facing_dir(toward),
		HexCoord.facing_dir(posmod(toward + 1, 6)),
		HexCoord.facing_dir(posmod(toward - 1, 6)),
	]
	for pc in player.cells():
		for sd in side_dirs:
			var n: Vector3i = pc + sd
			if not state.grid.in_bounds(n):
				continue
			var o2 := HexCoord.cube_to_offset(n)
			var key2 := "%d,%d" % [o2.x, o2.y]
			if seen.has(key2):
				continue
			seen[key2] = true
			cells.append([o2.x, o2.y])
	d["cells"] = cells
	d["dodgeable"] = true
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
