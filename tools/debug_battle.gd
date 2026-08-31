extends SceneTree
## 单场战斗的逐回合诊断 —— 排查"打不到敌人"
## godot --headless --path . -s res://tools/debug_battle.gd

func _initialize() -> void:
	CardInstance.reset_uid_counter()
	var setup := BattleSetup.create(
		_arg("hero", "knight"), _arg("layout", "open_hall"), _arg("enc", "enc_01"), 1)
	var state: BattleState = setup["state"]
	var flow: BattleFlow = setup["flow"]
	var deck: Array = setup["deck"]

	print("=== 初始布局 ===")
	for u in state.units:
		var o := HexCoord.cube_to_offset(u.anchor)
		print("  #%d %s team=%d @(%d,%d) f=%d HP=%d ATK=%d 体型=%s" % [
			u.id, u.display_name, int(u.team), o.x, o.y, u.facing,
			u.hp, u.atk, ["S","M","L"][int(u.size_class)]])
	print("  违规: %s" % str(state.rule_violations))
	print("")

	flow.battle_start(deck)

	for r in range(1, 7):
		if state.is_over:
			break
		var p := state.player()
		var enemies := state.alive_enemies()
		var po := HexCoord.cube_to_offset(p.anchor)
		print("── 回合 %d ── 玩家@(%d,%d) HP=%d 格挡=%d 体力=%d 手牌=%d" % [
			state.round_number, po.x, po.y, p.hp, p.block, state.energy, state.piles.hand.size()])
		for e in enemies:
			var eo := HexCoord.cube_to_offset(e.anchor)
			print("     敌 #%d %s @(%d,%d) HP=%d  距离=%d  意图=%s" % [
				e.id, e.display_name, eo.x, eo.y, e.hp,
				p.distance_to_unit(e), _intent_str(e.intent)])

		# 打印每张手牌的可选目标数与评分
		var hand_sorted: Array = state.piles.hand.duplicate()
		hand_sorted.sort_custom(func(a, b): return a.uid < b.uid)
		for c in hand_sorted:
			var cd: CardData = c.data
			var cost := RuleBook.card_cost(state, c.base_cost())
			var legal_n := 0
			var best_dmg := 0
			if cd.needs_target():
				var legal := TargetResolver.legal_cells(state, p, cd.target_spec)
				legal_n = legal.size()
				for cell in legal:
					var pv := flow.preview_card_damage(c, cell)
					for uid in pv:
						best_dmg = maxi(best_dmg, int(pv[uid]["min"]) * int(pv[uid]["repeat"]))
			print("       牌 %-10s cost=%d 合法目标格=%d 最高预计伤害=%d  射程=%s" % [
				cd.display_name, cost, legal_n, best_dmg,
				("%d-%d" % [cd.target_spec.range_min, cd.target_spec.range_max]) if cd.target_spec else "-"])

		# 走一个回合
		var acted := _greedy(state, flow)
		print("     本回合打出: %s" % (acted if acted != "" else "(无)"))
		if state.is_over:
			break
		flow.end_turn()
		print("")

	print("")
	print("结束: over=%s won=%s round=%d" % [state.is_over, state.player_won, state.round_number])
	quit(0)


func _arg(key: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() > 1 and kv[0].lstrip("-") == key:
			return kv[1]
	return def


func _intent_str(i: Dictionary) -> String:
	if i.is_empty():
		return "-"
	var kind: int = i.get("kind", 0)
	var names := ["ATTACK","MULTI","BUFF","DEBUFF","SUMMON","MOVE","ROTATE","SPECIAL","SLEEP"]
	var s: String = names[kind] if kind < names.size() else str(kind)
	if i.has("reason"):
		s += "(%s)" % i["reason"]
	if i.has("preview_min"):
		s += " 伤害%d" % i["preview_min"]
	if i.has("dodgeable"):
		s += " 可躲" if i["dodgeable"] else " 追踪"
	return s


func _greedy(state: BattleState, flow: BattleFlow) -> String:
	var played: Array[String] = []
	var guard := 0
	while guard < 20:
		guard += 1
		var best_card: CardInstance = null
		var best_cell := Vector3i.ZERO
		var best_score := -1.0
		var hand_sorted: Array = state.piles.hand.duplicate()
		hand_sorted.sort_custom(func(a, b): return a.uid < b.uid)
		for c in hand_sorted:
			var cd: CardData = c.data
			if cd == null:
				continue
			var cost := RuleBook.card_cost(state, c.base_cost())
			if cost > state.energy:
				continue
			var p := state.player()
			if p == null:
				break
			if cd.needs_target():
				for cell in TargetResolver.legal_cells(state, p, cd.target_spec):
					var sc := _score(state, flow, c, cell, cost)
					if sc > best_score:
						best_score = sc
						best_card = c
						best_cell = cell
			else:
				var sc2 := _score(state, flow, c, Vector3i.ZERO, cost)
				if sc2 > best_score:
					best_score = sc2
					best_card = c
					best_cell = Vector3i.ZERO
		if best_card == null or best_score <= 0.0:
			break
		if flow.play_card(best_card, best_cell):
			played.append(best_card.card_id())
		else:
			break
		if state.is_over:
			break
	return ",".join(played)


func _score(state: BattleState, flow: BattleFlow, c: CardInstance, cell: Vector3i, cost: int) -> float:
	var cd: CardData = c.data
	var score := 0.0
	var pv := flow.preview_card_damage(c, cell)
	for uid in pv:
		score += float(pv[uid]["min"]) * float(pv[uid]["repeat"])
	if score == 0.0:
		match cd.card_type:
			GameEnums.CardType.GUARD:
				score = 3.0
			GameEnums.CardType.MOVE:
				var p := state.player()
				var enemies := state.alive_enemies()
				if p != null and not enemies.is_empty():
					var before := p.distance_to_unit(enemies[0])
					var after := HexFootprint.distance_from(cell, p.footprint(), p.facing, enemies[0].anchor)
					score = 2.0 if after < before else 0.1
			GameEnums.CardType.SKILL:
				score = 2.0
			_:
				score = 0.5
	return score / float(maxi(1, cost))
