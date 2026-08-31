class_name ActionResolver
extends RefCounted
## GameAction 的处理器注册表 —— 纪律 2 的执行端
##
## 每种 action type 恰好一个处理器。data_linter 会校验
## Actions.all_types() 里的每一项都在这里注册了。
##
## ⚠️ 处理器是【唯一】能修改 BattleState 的地方。
##    任何其他地方写 unit.hp -= x 都是违规（check_discipline 会扫）。

var _handlers: Dictionary = {}


func _init() -> void:
	_register()


func _register() -> void:
	_handlers[Actions.DAMAGE] = _h_damage
	_handlers[Actions.GAIN_BLOCK] = _h_gain_block
	_handlers[Actions.HEAL] = _h_heal
	_handlers[Actions.MOVE] = _h_move
	_handlers[Actions.ROTATE] = _h_rotate
	_handlers[Actions.KNOCKBACK] = _h_knockback
	_handlers[Actions.PULL] = _h_pull
	_handlers[Actions.TRAMPLE] = _h_trample
	_handlers[Actions.APPLY_STATUS] = _h_apply_status
	_handlers[Actions.REMOVE_STATUS] = _h_noop
	_handlers[Actions.DRAW] = _h_draw
	_handlers[Actions.DISCARD] = _h_discard
	_handlers[Actions.EXHAUST] = _h_exhaust
	_handlers[Actions.RESHUFFLE] = _h_noop
	_handlers[Actions.GAIN_ENERGY] = _h_gain_energy
	_handlers[Actions.SPEND_ENERGY] = _h_spend_energy
	_handlers[Actions.MODIFY_STAT] = _h_modify_stat
	_handlers[Actions.DIE] = _h_die
	_handlers[Actions.HAZARD_TICK] = _h_hazard_tick


func has_handler(t: StringName) -> bool:
	return _handlers.has(t)


func registered_types() -> Array:
	var out: Array = _handlers.keys()
	out.sort()
	return out


func execute(a: GameAction, state, q: ActionQueue) -> void:
	state.log_action(a)
	if not _handlers.has(a.type):
		state.rule_violations.append({"kind": "no_handler", "type": String(a.type)})
		return
	var h: Callable = _handlers[a.type]
	h.call(a, state, q)


# ------------------------------------------------------------------ 处理器

func _h_noop(_a: GameAction, _state, _q: ActionQueue) -> void:
	pass


func _h_damage(a: GameAction, state, q: ActionQueue) -> void:
	var tgt: Unit = state.unit_by_id(a.data.get("tgt", -1))
	if tgt == null or not tgt.is_alive:
		return
	var packet: Dictionary = a.data.get("packet", {})
	if packet.get("dodged", false):
		state.log_event("damage_dealt", {"tgt": tgt.id, "dodged": true, "amount": 0})
		state.trigger_bus.emit(GameEnums.TriggerTiming.ON_DODGE,
			{"source_id": a.data.get("src", -1), "target_id": tgt.id}, state, q)
		return

	var to_block: int = packet.get("to_block", 0)
	var to_hp: int = packet.get("to_hp", 0)
	var block_before := tgt.block

	tgt.block = maxi(0, tgt.block - to_block)
	tgt.hp = maxi(0, tgt.hp - to_hp)

	state.log_event("damage_dealt", {
		"src": a.data.get("src", -1), "tgt": tgt.id,
		"amount": packet.get("final", 0), "to_block": to_block, "to_hp": to_hp,
		"crit": packet.get("crit", false), "hp_left": tgt.hp,
	})

	if packet.get("crit", false):
		state.trigger_bus.emit(GameEnums.TriggerTiming.ON_CRIT,
			{"source_id": a.data.get("src", -1), "target_id": tgt.id}, state, q)

	# 格挡被打破是一个独立时机（§6.3，最容易漏埋的钩子之一）
	if block_before > 0 and tgt.block == 0:
		state.trigger_bus.emit(GameEnums.TriggerTiming.ON_BLOCK_BROKEN,
			{"source_id": tgt.id}, state, q)

	state.trigger_bus.emit(GameEnums.TriggerTiming.ON_DAMAGE_DEALT,
		{"source_id": a.data.get("src", -1), "target_id": tgt.id,
		 "amount": packet.get("final", 0)}, state, q)
	state.trigger_bus.emit(GameEnums.TriggerTiming.ON_DAMAGE_TAKEN,
		{"source_id": tgt.id, "amount": to_hp}, state, q)

	if tgt.hp <= 0:
		q.push_next(Actions.die(tgt.id, a.source_tag))


func _h_gain_block(a: GameAction, state, q: ActionQueue) -> void:
	var u: Unit = state.unit_by_id(a.data.get("tgt", -1))
	if u == null or not u.is_alive:
		return
	# 《巨化》的代价：无法获得格挡（走 RuleBook 单消费点）
	if u.team == GameEnums.Team.PLAYER and not RuleBook.can_gain_block(state):
		state.log_event("block_gained", {"tgt": u.id, "amount": 0, "blocked_by_rule": true})
		return
	var amount := int(round(float(a.data.get("amount", 0)) * RuleBook.block_multiplier(state)))
	u.block += amount
	state.log_event("block_gained", {"tgt": u.id, "amount": amount, "total": u.block})
	state.trigger_bus.emit(GameEnums.TriggerTiming.ON_BLOCK_GAINED,
		{"source_id": u.id, "amount": amount}, state, q)


func _h_heal(a: GameAction, state, _q: ActionQueue) -> void:
	var u: Unit = state.unit_by_id(a.data.get("tgt", -1))
	if u == null or not u.is_alive:
		return
	var before := u.hp
	u.hp = mini(u.hp_max, u.hp + int(a.data.get("amount", 0)))
	state.log_event("healed", {"tgt": u.id, "amount": u.hp - before, "hp": u.hp})


func _h_move(a: GameAction, state, q: ActionQueue) -> void:
	var u: Unit = state.unit_by_id(a.data.get("unit", -1))
	if u == null or not u.is_alive:
		return
	var path: Array = a.data.get("path", [])
	if path.is_empty():
		return
	var dest_offset: Array = path[path.size() - 1]
	var dest := HexCoord.offset_to_cube(dest_offset[0], dest_offset[1])
	var new_facing: int = a.data.get("facing", -1)
	if new_facing < 0:
		new_facing = u.facing
	var from_offset := HexCoord.cube_to_offset(u.anchor)

	# 已经在目标格 → 只需转向（不算非法）
	if u.anchor == dest:
		if new_facing != u.facing:
			q.push_next(Actions.rotate_unit(u.id, new_facing, a.source_tag))
		return

	# ⚠️ 移动与朝向的关系（连续踩过两次，务必读完）：
	#   寻路是在 (anchor, facing) 状态图上搜的，它给出的"到达该锚点时的朝向"
	#   本身就是可达的。但移动到目标锚点时，【当前朝向可能放不下】——
	#   实测：石傀(M) f=5 想移到 (2,5)，f=5 需要 (2,4)=墙，必须先转向。
	#   所以正确顺序是：
	#     1) 先试目标朝向（寻路算出的那个）
	#     2) 再试当前朝向
	#     3) 再试其余任意可行朝向（体型系统下总有若干姿态可行）
	#   而不是死板地"先移动后转向"或"必须同时满足"。
	var moved: bool = false
	var used_facing := u.facing
	var facing_candidates: Array[int] = []
	if new_facing >= 0 and new_facing != u.facing:
		facing_candidates.append(new_facing)
	facing_candidates.append(u.facing)
	for f in range(6):
		if not f in facing_candidates:
			facing_candidates.append(f)

	for f in facing_candidates:
		if state.relocate_unit(u, dest, f):
			moved = true
			used_facing = f
			break

	if not moved:
		# 落点整体放不下（入队与执行之间战场已变）→ 就地重算一条路径。
		# 不重算会在 200 场里刷出大量假违规。
		var repath := HexPathfinder.path_to(state.grid, u, dest, -1, 99, state)
		if repath.is_empty():
			state.log_event("move_aborted", {
				"unit": u.id, "to": dest_offset, "reason": "落点不可达",
			})
			return
		var last: Array = repath[repath.size() - 1]
		var d2 := HexCoord.offset_to_cube(last[0], last[1])
		for f2 in facing_candidates:
			if state.relocate_unit(u, d2, f2):
				moved = true
				used_facing = f2
				break
		if not moved:
			# 连重算路径的终点、任意朝向都放不下 → 真异常（逻辑/数据错误）
			state.rule_violations.append({
				"kind": "illegal_move", "unit": u.id, "to": last,
			})
			return
		path = repath
		dest_offset = last

	# 到位后若还想转到别的朝向，单独排一个转向动作（转不过身只记事件）
	if new_facing >= 0 and new_facing != used_facing:
		q.push_next(Actions.rotate_unit(u.id, new_facing, a.source_tag))

	state.log_event("unit_moved", {
		"unit": u.id, "from": [from_offset.x, from_offset.y],
		"to": dest_offset, "facing": u.facing, "path": path,
	})

	var timing := GameEnums.TriggerTiming.ON_MOVE_SELF if u.team == GameEnums.Team.PLAYER \
			else GameEnums.TriggerTiming.ON_MOVE_ENEMY
	state.trigger_bus.emit(timing, {"source_id": u.id}, state, q)

	_check_hazards(u, state, q)


func _h_rotate(a: GameAction, state, q: ActionQueue) -> void:
	var u: Unit = state.unit_by_id(a.data.get("unit", -1))
	if u == null or not u.is_alive:
		return
	var f: int = a.data.get("facing", u.facing)
	if f == u.facing:
		return
	# ⚠️ 多格单位转向会改变占位（§8.2.2 机制点 5）。转不过身【不是违规】，
	#    而是体型系统的正常后果 —— 这正是"把 Boss 逼到墙角让它转不过身"
	#    这类战术的来源（§8.2.3）。所以只记事件，不写 rule_violations，
	#    否则 M/L 单位会在 battle_sim 里刷出大量假违规（实测 37 次/30 场）。
	if not state.relocate_unit(u, u.anchor, f):
		state.log_event("rotate_blocked", {
			"unit": u.id, "want_facing": f, "cur_facing": u.facing,
			"reason": "转向后占位不合法（空间不足）",
		})
		return
	state.log_event("unit_rotated", {"unit": u.id, "facing": f})


func _h_knockback(a: GameAction, state, q: ActionQueue) -> void:
	_displace(a, state, q, 1)


func _h_pull(a: GameAction, state, q: ActionQueue) -> void:
	_displace(a, state, q, -1)


## 位移的共同实现。sign=1 击退，sign=-1 拉近。
## §8.2.2 机制点 4：位移抗性按体型（S=0 / M=1 / L=免疫）
func _displace(a: GameAction, state, q: ActionQueue, sign: int) -> void:
	var u: Unit = state.unit_by_id(a.data.get("unit", -1))
	if u == null or not u.is_alive:
		return
	var resist := RuleBook.knockback_resist_of(state, u)
	var dist := int(a.data.get("dist", 0)) - resist
	if dist <= 0:
		state.log_event("knockback_resisted", {"unit": u.id, "resist": resist})
		return

	var d := HexCoord.DIRS[posmod(int(a.data.get("dir", 0)), 6)] * sign
	var moved := 0
	for _i in range(dist):
		var next: Vector3i = u.anchor + d
		if not state.relocate_unit(u, next, u.facing):
			# 撞墙/撞单位 → 停止（§8.6：撞墙可产生额外伤害，由卡牌效果单独处理）
			state.log_event("displace_blocked", {"unit": u.id, "moved": moved})
			break
		moved += 1
	if moved > 0:
		var o := HexCoord.cube_to_offset(u.anchor)
		state.log_event("unit_moved", {
			"unit": u.id, "to": [o.x, o.y], "facing": u.facing, "displaced": true,
		})
		_check_hazards(u, state, q)


func _h_trample(a: GameAction, state, q: ActionQueue) -> void:
	# §8.2.2 机制点 6：碾压比自己小的单位
	var u: Unit = state.unit_by_id(a.data.get("unit", -1))
	if u == null or not u.can_trample_below():
		return
	state.log_event("trample", {"unit": u.id})


func _h_apply_status(a: GameAction, state, q: ActionQueue) -> void:
	# P2 接入 StatusSystem，P1 只记录事件
	var tgt: Unit = state.unit_by_id(a.data.get("tgt", -1))
	if tgt == null:
		return
	state.log_event("status_applied", {
		"tgt": tgt.id, "status": a.data.get("status", ""),
		"stacks": a.data.get("stacks", 0),
	})
	state.trigger_bus.emit(GameEnums.TriggerTiming.ON_STATUS_APPLIED,
		{"source_id": tgt.id, "status": a.data.get("status", "")}, state, q)


func _h_draw(a: GameAction, state, q: ActionQueue) -> void:
	var n := int(a.data.get("count", 0))
	var events: Array = []
	state.piles.draw(n, RuleBook.hand_limit(state), state.rng, events)
	for e in events:
		state.event_log.append(e)
		if e.get("t") == "deck_reshuffled":
			state.trigger_bus.emit(GameEnums.TriggerTiming.ON_DECK_RESHUFFLED, {}, state, q)
		elif e.get("t") == "card_drawn":
			state.trigger_bus.emit(GameEnums.TriggerTiming.ON_CARD_DRAWN,
				{"uid": e["d"].get("uid", 0)}, state, q)


func _h_discard(a: GameAction, state, q: ActionQueue) -> void:
	var uid := int(a.data.get("uid", -1))
	var c: CardInstance = state.piles.find_in_hand(uid)
	if c == null:
		return
	var events: Array = []
	state.piles.discard_one(c, events)
	for e in events:
		state.event_log.append(e)
	state.trigger_bus.emit(GameEnums.TriggerTiming.ON_CARD_DISCARDED, {"uid": uid}, state, q)


func _h_exhaust(a: GameAction, state, q: ActionQueue) -> void:
	var uid := int(a.data.get("uid", -1))
	var c: CardInstance = state.piles.find_in_hand(uid)
	if c == null:
		return
	var events: Array = []
	state.piles.resolve_played_card(c, true, events)
	for e in events:
		state.event_log.append(e)
	state.trigger_bus.emit(GameEnums.TriggerTiming.ON_CARD_EXHAUSTED, {"uid": uid}, state, q)


func _h_gain_energy(a: GameAction, state, _q: ActionQueue) -> void:
	state.energy += int(a.data.get("amount", 0))
	state.log_event("energy_changed", {"energy": state.energy})


func _h_spend_energy(a: GameAction, state, _q: ActionQueue) -> void:
	state.energy = maxi(0, state.energy - int(a.data.get("amount", 0)))
	state.log_event("energy_changed", {"energy": state.energy})


func _h_modify_stat(a: GameAction, state, _q: ActionQueue) -> void:
	var u: Unit = state.unit_by_id(a.data.get("unit", -1))
	if u == null:
		return
	var stat: String = a.data.get("stat", "")
	var delta := int(a.data.get("delta", 0))
	match stat.to_upper():
		"ATK": u.atk += delta
		"DEF": u.def += delta
		"AGI": u.agi += delta
		"LUK": u.luk += delta
		"CRIT": u.crit += delta
		"HP_MAX":
			u.hp_max += delta
			u.hp = mini(u.hp, u.hp_max)
	state.log_event("stat_modified", {"unit": u.id, "stat": stat, "delta": delta})


func _h_die(a: GameAction, state, q: ActionQueue) -> void:
	var u: Unit = state.unit_by_id(a.data.get("unit", -1))
	if u == null or not u.is_alive:
		return
	state.kill_unit(u)
	state.trigger_bus.emit(GameEnums.TriggerTiming.ON_UNIT_DEATH, {"source_id": u.id}, state, q)
	if u.team == GameEnums.Team.ENEMY:
		state.trigger_bus.emit(GameEnums.TriggerTiming.ON_KILL, {"target_id": u.id}, state, q)
	state.check_victory()


func _h_hazard_tick(a: GameAction, state, _q: ActionQueue) -> void:
	var u: Unit = state.unit_by_id(a.data.get("unit", -1))
	if u == null or not u.is_alive:
		return
	# ⚠️ 大体型同时站多个 hazard 时【每格各结算一次】（§8.2.2 机制点 7）
	var cells := int(a.data.get("cells", 1))
	var per_cell := 3
	var total := per_cell * cells
	u.hp = maxi(0, u.hp - total)
	state.log_event("hazard_damage", {"unit": u.id, "cells": cells, "amount": total, "hp": u.hp})
	if u.hp <= 0:
		state.kill_unit(u)
		state.check_victory()


## 移动后检查踩到的 hazard
func _check_hazards(u: Unit, state, q: ActionQueue) -> void:
	var n := 0
	for c in u.cells():
		if state.grid.hazard_at(c) != GameEnums.Hazard.NONE:
			n += 1
	if n > 0:
		q.push_next(Actions.hazard_tick(u.id, int(GameEnums.Hazard.SPIKES), n, "terrain"))
