class_name BattleSetup
## 战斗初始化 —— §8.4 BattleStart 的准备工作
##
## 独立成文件的理由：battle_sim / 单测 / 真实场景都需要"造一场战斗"，
## 且都必须走同一条路径，否则模拟出来的结论对真实游戏不成立。

## 造一场战斗。返回 {state, flow, deck}。
##
## ⚠️ 敌人放不下时走 §8.8 的 fallback：降级体型重试，
##    避免 M/L 敌人在狭窄地形上"生成失败导致空战斗"。
static func create(
	hero_id: String, layout_id: String, encounter_id: String,
	seed_value: int, floor_index: int = 1, corruption: int = 0
) -> Dictionary:
	var rng := RngStreams.new(seed_value)
	var state := BattleState.new(rng)
	state.grid = ContentLibrary.layout_by_id(layout_id)

	# ---- 英雄
	var hero := ContentLibrary.hero_by_id(hero_id)
	state.hero_energy_max_base = hero.energy_max
	state.hero_draw_base = hero.cards_drawn_per_turn
	# 被动天赋 → rule_agg（P4 接入符文后由 RuneLoadout 统一聚合）
	state.rule_agg = hero.passive_rules.duplicate()

	var player := Unit.new()
	hero.apply_to_unit(player)
	var spawn := HexCoord.offset_to_cube(K.HERO_SPAWN_COL, K.HERO_SPAWN_ROW)
	if not state.add_unit(player, spawn, K.HERO_SPAWN_FACING):
		# 出生点放不下（地形模板设计错误）→ 找最近可行位置
		var placed := false
		for row in range(1, 4):
			for col in range(1, 8):
				var a := HexCoord.offset_to_cube(col, row)
				if state.add_unit(player, a, K.HERO_SPAWN_FACING):
					placed = true
					break
			if placed:
				break
		if not placed:
			state.rule_violations.append({"kind": "hero_spawn_failed", "layout": layout_id})

	# ---- 敌人（§8.8：生成在上半区，距玩家 >= 2）
	var spawn_cells := _enemy_spawn_cells(state, player)
	var idx := 0
	for entry in ContentLibrary.encounter(encounter_id):
		var ed := ContentLibrary.enemy_by_id(entry["enemy_id"])
		if ed == null:
			continue
		for _i in range(entry.get("count", 1)):
			var placed_ok := false
			# 尝试所有候选格 × 所有朝向
			while idx < spawn_cells.size() and not placed_ok:
				var cell: Vector3i = spawn_cells[idx]
				for f in range(6):
					var e := ed.make_unit(floor_index, corruption)
					if state.add_unit(e, cell, f):
						placed_ok = true
						break
				idx += 1
			if not placed_ok:
				# §8.8 fallback：降级体型重试（L→M→S）
				placed_ok = _try_fallback(state, ed, spawn_cells, floor_index, corruption)
			if not placed_ok:
				state.rule_violations.append({
					"kind": "enemy_spawn_failed", "enemy": ed.id, "layout": layout_id,
				})

	# ---- 卡组
	var deck := ContentLibrary.starting_deck(hero)
	state.deck_capacity_base = maxi(deck.size(), 20)

	var flow := BattleFlow.new(state)
	return {"state": state, "flow": flow, "deck": deck}


## 敌人候选生成格：上半区，距玩家 footprint >= ENEMY_SPAWN_MIN_DIST
## 按 (row 降序, col 升序) 固定顺序 —— 确定性（纪律 5）
static func _enemy_spawn_cells(state: BattleState, player: Unit) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for row in range(K.ENEMY_SPAWN_ROW_MAX, K.ENEMY_SPAWN_ROW_MIN - 1, -1):
		for col in range(1, K.BOARD_COLS + 1):
			var c := HexCoord.offset_to_cube(col, row)
			if not state.grid.is_walkable(c):
				continue
			if player != null and player.distance_to_cell(c) < K.ENEMY_SPAWN_MIN_DIST:
				continue
			out.append(c)
	return out


## §8.8 的 fallback_enemies：体型降级重试
static func _try_fallback(
	state: BattleState, ed: EnemyData, cells: Array[Vector3i],
	floor_index: int, corruption: int
) -> bool:
	var downgrades := {
		GameEnums.SizeClass.L: GameEnums.SizeClass.M,
		GameEnums.SizeClass.M: GameEnums.SizeClass.S,
	}
	var size := ed.size_class
	while downgrades.has(size):
		size = downgrades[size]
		for cell in cells:
			for f in range(6):
				var e := ed.make_unit(floor_index, corruption)
				e.size_class = size
				e.size_data = SizeClassData.make(size)
				e.display_name += "(降级)"
				if state.add_unit(e, cell, f):
					state.log_event("enemy_downgraded", {
						"enemy": ed.id, "from": int(ed.size_class), "to": int(size),
					})
					return true
	return false
