class_name BattleFlow
extends RefCounted
## 回合状态机 —— §8.4
##
## BattleStart → RoundStart → PlayerPhase → RoundEndPlayer → EnemyPhase
##             → RoundEndAll →（循环回 RoundStart）
## 终态：BattleWin（内含 EXPLORE 拾取 → EXIT_GATE）/ BattleLose
##
## ⚠️ 纪律 3：本文件【不等待动画】。逻辑瞬时算完，表现层按 event_log 回放。
##    所以这里没有任何 await / timer。

var state: BattleState = null
var resolver: ActionResolver = null


func _init(p_state: BattleState) -> void:
	state = p_state
	resolver = ActionResolver.new()
	state.queue.resolver = resolver
	if state.trigger_bus == null:
		state.trigger_bus = TriggerBus.new()


# ══════════════════════════════════════════════════════ BattleStart

## 开始战斗。deck 是 CardInstance 数组。
func battle_start(deck: Array) -> void:
	state.phase = GameEnums.BattlePhase.BATTLE_START
	state.round_number = 0
	state.trigger_bus.reset_battle_counters()
	state.log_event("battle_started", {"units": state.units.size()})

	# 卡组 → 洗混 → 抽牌堆（§7.4.2 步骤 1）
	state.piles.build_from_deck(deck, state.rng, RuleBook.deck_capacity(state))

	# ON_BATTLE_START（§7.4.2 步骤 2）
	_emit(GameEnums.TriggerTiming.ON_BATTLE_START, {})
	_resolve()

	# 生成敌方首个意图并显示（§8.4）
	_refresh_all_intents()

	# 进入第一回合
	round_start()


# ══════════════════════════════════════════════════════ RoundStart

func round_start() -> void:
	if state.is_over:
		return
	state.phase = GameEnums.BattlePhase.ROUND_START
	state.round_number += 1
	state.cards_played_this_round = 0
	state.trigger_bus.reset_round_counters()
	state.log_event("round_started", {"round": state.round_number})

	# ON_ROUND_START（符文按槽位 1→6 结算）
	_emit(GameEnums.TriggerTiming.ON_ROUND_START, {})
	_resolve()

	# 状态 tick（P2 接入 StatusSystem）

	# 抽牌（§7.4.2）
	if not RuleBook.is_fixed_hand(state):
		var n := RuleBook.cards_drawn_per_turn(state)
		state.queue.push_back(Actions.draw(n, "round_start"))
		_resolve()

	# 体力 = 上限
	state.energy = RuleBook.energy_max(state)
	state.log_event("energy_changed", {"energy": state.energy})

	state.phase = GameEnums.BattlePhase.PLAYER_PHASE
	state.log_event("phase_changed", {"phase": int(state.phase)})


# ══════════════════════════════════════════════════════ PlayerPhase

## 打出一张手牌。返回是否成功。
##
## chosen_cell 是玩家选定的目标格（SELF 类卡可传 Vector3i.ZERO）。
func play_card(card: CardInstance, chosen_cell: Vector3i) -> bool:
	if state.phase != GameEnums.BattlePhase.PLAYER_PHASE or state.is_over:
		return false
	var player := state.player()
	if player == null or not player.is_alive:
		return false
	if not state.piles.hand.has(card):
		return false

	var cost := RuleBook.card_cost(state, card.base_cost())
	if cost > state.energy:
		state.log_event("play_rejected", {"reason": "体力不足", "need": cost, "have": state.energy})
		return false

	var cd := card.data
	if cd == null:
		return false

	# 目标合法性
	if cd.needs_target():
		var legal := TargetResolver.legal_cells(state, player, cd.target_spec)
		if not legal.has(chosen_cell):
			state.log_event("play_rejected", {"reason": "目标非法"})
			return false

	# 支付体力
	state.queue.push_back(Actions.spend_energy(cost, "card:" + cd.id))
	state.cards_played_this_round += 1

	# 结算效果
	_execute_card_effects(cd, player, chosen_cell)

	# 归宿：消耗区 or 弃牌堆（§7.4.2 步骤 4）
	var exhaust := cd.is_exhaust or (cd.is_attack() and RuleBook.attacks_exhaust(state))
	var events: Array = []
	state.piles.resolve_played_card(card, exhaust, events)
	for e in events:
		state.event_log.append(e)

	state.log_event("card_played", {"uid": card.uid, "id": cd.id, "cost": cost})
	_emit(GameEnums.TriggerTiming.ON_CARD_PLAYED, {"card_id": cd.id, "source_id": player.id})

	_resolve()
	state.check_victory()
	if state.is_over:
		_on_battle_end()
	return true


func _execute_card_effects(cd: CardData, player: Unit, chosen_cell: Vector3i) -> void:
	var tag := "card:" + cd.id
	for step in cd.effects:
		for _rep in range(maxi(1, step.repeat)):
			_execute_step(step, cd, player, chosen_cell, tag)


func _execute_step(step: EffectStep, cd: CardData, player: Unit, chosen: Vector3i, tag: String) -> void:
	match step.op:
		GameEnums.EffectOp.DEAL_DAMAGE:
			var targets := TargetResolver.affected_units(state, player, cd.target_spec, chosen)
			for t in targets:
				var ctx := DamageCalculator.Context.new()
				ctx.source = player
				ctx.target = t
				ctx.flat = step.flat_value
				ctx.stat_ref = step.stat_ref
				ctx.stat_ratio = step.stat_ratio
				ctx.tags = cd.tags
				ctx.from_rear = t.is_attacked_from_rear(player.anchor)
				# ②′ 顺序钩子：符文按槽位 1→6 作用（§6.5）
				var hook: Callable = state.trigger_bus.make_value_hook(GameEnums.TriggerTiming.ON_ATTACK)
				var r := DamageCalculator.calculate(ctx, state.rng, hook)
				state.queue.push_back(Actions.damage(player.id, t.id, r.to_dict(), tag))
			_emit(GameEnums.TriggerTiming.ON_ATTACK, {"source_id": player.id, "card_id": cd.id})

		GameEnums.EffectOp.GAIN_BLOCK:
			var amount := DamageCalculator.calculate_block(
				player, step.flat_value, step.stat_ref, step.stat_ratio)
			state.queue.push_back(Actions.gain_block(player.id, amount, tag))

		GameEnums.EffectOp.HEAL:
			state.queue.push_back(Actions.heal(player.id, int(step.value_for(player)), tag))

		GameEnums.EffectOp.MOVE_SELF, GameEnums.EffectOp.DASH, GameEnums.EffectOp.BLINK:
			var budget := step.distance
			if budget <= 0:
				budget = cd.target_spec.range_max if cd.target_spec != null else 1
			# AGI 的次要收益：移动卡额外位移（§4.3）
			budget += player.agi / K.K_AGI_PER_STEP
			var path := HexPathfinder.path_to(state.grid, player, chosen, -1, budget, state)
			if not path.is_empty():
				var f := HexPathfinder.best_facing_at(state.grid, player, chosen, budget, state)
				state.queue.push_back(Actions.move(player.id, path, f, tag))

		GameEnums.EffectOp.KNOCKBACK:
			for t in TargetResolver.affected_units(state, player, cd.target_spec, chosen):
				var di := _dir_index_from_to(player.anchor, t.anchor)
				state.queue.push_back(Actions.knockback(t.id, di, step.distance, tag))

		GameEnums.EffectOp.PULL:
			for t in TargetResolver.affected_units(state, player, cd.target_spec, chosen):
				var di2 := _dir_index_from_to(player.anchor, t.anchor)
				state.queue.push_back(Actions.pull(t.id, di2, step.distance, tag))

		GameEnums.EffectOp.ROTATE:
			state.queue.push_back(Actions.rotate_unit(player.id, step.distance, tag))

		GameEnums.EffectOp.APPLY_STATUS:
			for t in TargetResolver.affected_units(state, player, cd.target_spec, chosen):
				state.queue.push_back(
					Actions.apply_status(t.id, step.status_id, step.status_stacks, tag))

		GameEnums.EffectOp.DRAW_CARD:
			state.queue.push_back(Actions.draw(maxi(1, step.repeat), tag))

		GameEnums.EffectOp.GAIN_ENERGY:
			state.queue.push_back(Actions.gain_energy(int(step.value_for(player)), tag))

		_:
			state.log_event("unimplemented_op", {"op": int(step.op), "card": cd.id})


static func _dir_index_from_to(from: Vector3i, to: Vector3i) -> int:
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


# ══════════════════════════════════════════════════════ 回合结束

## 玩家主动结束回合（§8.4 RoundEndPlayer）
func end_turn() -> void:
	if state.phase != GameEnums.BattlePhase.PLAYER_PHASE or state.is_over:
		return
	state.phase = GameEnums.BattlePhase.ROUND_END_PLAYER

	# ON_ROUND_END（格挡清空等）
	_emit(GameEnums.TriggerTiming.ON_ROUND_END, {})
	_resolve()

	# 格挡清空 —— 除非 BLOCK_PERSISTS（骑士被动，走 RuleBook 单消费点）
	if not RuleBook.block_persists(state):
		for u in state.alive_units():
			if u.team == GameEnums.Team.PLAYER:
				u.block = 0
				state.log_event("block_cleared", {"unit": u.id})

	# 弃掉全部手牌，每张触发 ON_CARD_DISCARDED（§7.4.2）
	var events: Array = []
	var n := state.piles.discard_hand(events)
	for e in events:
		state.event_log.append(e)
	if n > 0:
		_emit(GameEnums.TriggerTiming.ON_CARD_DISCARDED, {"count": n})
		_resolve()

	# 剩余体力 → ON_ENERGY_LEFTOVER → 清零
	# ⚠️ 这是《余烬》符文的钩子，也是「沉重+余烬」组合的关键（§6.3 示例 C+D）
	if state.energy > 0:
		_emit(GameEnums.TriggerTiming.ON_ENERGY_LEFTOVER, {"amount": state.energy})
		_resolve()
	state.energy = 0

	enemy_phase()


# ══════════════════════════════════════════════════════ EnemyPhase

func enemy_phase() -> void:
	if state.is_over:
		return
	state.phase = GameEnums.BattlePhase.ENEMY_PHASE
	state.log_event("phase_changed", {"phase": int(state.phase)})

	# 按 AGI 降序 + id tiebreak 依次行动（§8.4 + 纪律 5）
	for enemy in state.enemies_in_action_order():
		if not enemy.is_alive or state.is_over:
			continue
		EnemyAI.execute_intent(state, enemy, state.queue)
		_resolve()
		# 行动后更新朝向（多格单位需校验占位）
		var f: int = enemy.intent.get("facing", -1)
		if f >= 0 and enemy.is_alive:
			state.queue.push_back(Actions.rotate_unit(enemy.id, f, "enemy_ai"))
			_resolve()
		state.check_victory()

	if state.is_over:
		_on_battle_end()
		return

	round_end_all()


# ══════════════════════════════════════════════════════ RoundEndAll

func round_end_all() -> void:
	state.phase = GameEnums.BattlePhase.ROUND_END_ALL

	# 危害地面 tick（站在 hazard 上的单位每格各结算一次 —— §8.2.2 机制点 7）
	for u in state.alive_units():
		var n := 0
		for c in u.cells():
			if state.grid.hazard_at(c) != GameEnums.Hazard.NONE:
				n += 1
		if n > 0:
			state.queue.push_back(Actions.hazard_tick(u.id, int(GameEnums.Hazard.SPIKES), n, "terrain"))
	_resolve()

	# 状态持续时间 -1（P2）

	state.check_victory()
	if state.is_over:
		_on_battle_end()
		return

	# 生成下回合意图并立即显示（§8.4）
	_refresh_all_intents()

	round_start()


# ══════════════════════════════════════════════════════ 结束

func _on_battle_end() -> void:
	if state.player_won:
		_emit(GameEnums.TriggerTiming.ON_BATTLE_WIN, {})
		_resolve()
		# EXPLORE 拾取阶段（§8.4）—— P6 接入掉落后才有意义
		state.phase = GameEnums.BattlePhase.EXPLORE
	else:
		state.phase = GameEnums.BattlePhase.BATTLE_LOSE
	state.log_event("phase_changed", {"phase": int(state.phase)})


# ══════════════════════════════════════════════════════ 内部

func _emit(timing: int, ctx: Dictionary) -> void:
	state.trigger_bus.emit(timing, ctx, state, state.queue)


func _resolve() -> void:
	state.queue.resolve_all(state)


func _refresh_all_intents() -> void:
	for enemy in state.enemies_in_action_order():
		if not enemy.is_alive:
			continue
		enemy.intent = EnemyAI.decide(state, enemy)
		enemy.intent["_src"] = enemy.id
		state.log_event("intent_updated", {"unit": enemy.id, "intent": enemy.intent})


## 伤害预览（§13.2 硬性要求）。⚠️ 不消耗 RNG。
func preview_card_damage(card: CardInstance, chosen: Vector3i) -> Dictionary:
	var player := state.player()
	if player == null or card.data == null:
		return {}
	var step := card.data.primary_damage_step()
	if step == null:
		return {}
	var targets := TargetResolver.affected_units(state, player, card.data.target_spec, chosen)
	var out := {}
	for t in targets:
		var ctx := DamageCalculator.Context.new()
		ctx.source = player
		ctx.target = t
		ctx.flat = step.flat_value
		ctx.stat_ref = step.stat_ref
		ctx.stat_ratio = step.stat_ratio
		ctx.from_rear = t.is_attacked_from_rear(player.anchor)
		var hook: Callable = state.trigger_bus.make_value_hook(GameEnums.TriggerTiming.ON_ATTACK)
		var pv := DamageCalculator.preview(ctx, hook)
		out[t.id] = {"min": pv.x, "max": pv.y, "repeat": maxi(1, step.repeat)}
	return out
