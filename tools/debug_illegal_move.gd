extends SceneTree
## 抓一个 illegal_move 的具体现场
## godot --headless --path . -s res://tools/debug_illegal_move.gd

func _initialize() -> void:
	for seed_i in range(500, 540):
		CardInstance.reset_uid_counter()
		var setup := BattleSetup.create("giant", "narrow_pass", "enc_03", seed_i)
		var state: BattleState = setup["state"]
		var flow: BattleFlow = setup["flow"]
		flow.battle_start(setup["deck"])

		while not state.is_over and state.round_number <= 50:
			_greedy(state, flow)
			if state.is_over:
				break
			flow.end_turn()
			# 找到第一个违规就详细打印
			for v in state.rule_violations:
				if v.get("kind") == "illegal_move":
					print("=== seed=%d 回合=%d 发现 illegal_move ===" % [seed_i, state.round_number])
					print("  违规详情: %s" % str(v))
					var u: Unit = state.unit_by_id(v.get("unit", -1))
					if u != null:
						var o := HexCoord.cube_to_offset(u.anchor)
						print("  单位 #%d %s 体型=%s 当前@(%d,%d) f=%d" % [
							u.id, u.display_name, ["S","M","L"][int(u.size_class)],
							o.x, o.y, u.facing])
						print("  当前占格: %s" % _cells_str(u))
						var target: Array = v.get("to", [])
						if target.size() == 2:
							var tc := HexCoord.offset_to_cube(target[0], target[1])
							print("  目标锚点 (%d,%d)" % [target[0], target[1]])
							for f in range(6):
								var ok := HexFootprint.can_place(state.grid, tc, u.footprint(), f, u.id)
								var why := HexFootprint.place_failure_reason(state.grid, tc, u.footprint(), f, u.id)
								print("    facing=%d 可放置=%s %s" % [f, ok, ("(%s)" % why) if why != "" else ""])
					print("  战场其他单位:")
					for other in state.alive_units():
						if other.id == u.id:
							continue
						var oo := HexCoord.cube_to_offset(other.anchor)
						print("    #%d %s @(%d,%d) 占格=%s" % [
							other.id, other.display_name, oo.x, oo.y, _cells_str(other)])
					quit(0)
					return
	print("40 个 seed 内未复现")
	quit(0)


func _cells_str(u: Unit) -> String:
	var parts: Array[String] = []
	for c in u.cells():
		var o := HexCoord.cube_to_offset(c)
		parts.append("(%d,%d)" % [o.x, o.y])
	return " ".join(parts)


func _greedy(state: BattleState, flow: BattleFlow) -> void:
	var guard := 0
	while guard < 20:
		guard += 1
		var best: CardInstance = null
		var best_cell := Vector3i.ZERO
		var best_score := -1.0
		var hand: Array = state.piles.hand.duplicate()
		hand.sort_custom(func(a, b): return a.uid < b.uid)
		for c in hand:
			var cd: CardData = c.data
			if cd == null:
				continue
			var cost := RuleBook.card_cost(state, c.base_cost())
			if cost > state.energy:
				continue
			var p := state.player()
			if p == null:
				return
			if cd.needs_target():
				for cell in TargetResolver.legal_cells(state, p, cd.target_spec):
					var sc := _score(state, flow, c, cell, cost)
					if sc > best_score:
						best_score = sc
						best = c
						best_cell = cell
			else:
				var sc2 := _score(state, flow, c, Vector3i.ZERO, cost)
				if sc2 > best_score:
					best_score = sc2
					best = c
					best_cell = Vector3i.ZERO
		if best == null or best_score <= 0.0:
			return
		if not flow.play_card(best, best_cell):
			return
		if state.is_over:
			return


func _score(state: BattleState, flow: BattleFlow, c: CardInstance, cell: Vector3i, cost: int) -> float:
	var cd: CardData = c.data
	var score := 0.0
	var pv := flow.preview_card_damage(c, cell)
	for uid in pv:
		score += float(pv[uid]["min"]) * float(pv[uid]["repeat"])
	if score == 0.0:
		match cd.card_type:
			GameEnums.CardType.GUARD: score = 3.0
			GameEnums.CardType.MOVE:
				var p := state.player()
				var en := state.alive_enemies()
				if p != null and not en.is_empty():
					var before := p.distance_to_unit(en[0])
					var after := HexFootprint.distance_from(cell, p.footprint(), p.facing, en[0].anchor)
					score = 2.0 if after < before else 0.1
			GameEnums.CardType.SKILL: score = 2.0
			_: score = 0.5
	return score / float(maxi(1, cost))
