class_name TriggerBus
extends RefCounted
## D6：统一触发时机分发 —— §6.3 / §6.5
##
## P1 只做 emit（无监听者，开销近零）；P4 接入符文后补全监听者构建。
## ⚠️ 为什么 P1 就要把 emit 点埋满：
##    事后补钩子必然漏 —— ON_BLOCK_BROKEN / ON_DECK_RESHUFFLED 这类冷门时机
##    最容易忘。埋点时监听者为空几乎零成本，回填却要重读整个战斗流程。
##
## ══ 五条保证机制（R7 / §6.5）══
## 1. 监听者数组是【唯一顺序来源】，禁止 Dictionary 遍历：
##      [英雄被动(虚拟槽0)] → [符文槽1..6 跳null] → [装备 WEAPON,ARMOR,TRINKET]
##      → [状态：按 (unit_id, status_id, 实例下标) 显式排序]
## 2. emit 入口【冻结】监听者列表 —— 遍历中被改会造成未定义行为与不确定性
## 3. 递归深度 ≥ MAX_TRIGGER_DEPTH → 停止分发 + 写 rule_violations，绝不抛异常
## 4. max_per_round / max_per_battle 计数键用 source_uid（实例 uid，非 id，
##    避免同名符文串号）；Dictionary 只查表不遍历
## 5. 单次 emit 触发总数上限 —— 兜住"A 触发 B、B 触发 A"这种
##    深度=2 但宽度爆炸的组合（策划案 R7 只提了深度，这条是补的）

## 一个监听者条目
class Listener:
	var source_uid: int = 0          ## 实例唯一 id（符文/装备/状态实例）
	var source_tag: String = ""      ## "rune:slot3" / "passive" / "status:burn"
	var slot_order: int = 0          ## 排序键：被动=0，符文槽=1..6，装备=10..12，状态=20+
	var timing: int = 0
	var effects: Array = []          ## Array[EffectStep]
	var max_per_round: int = -1
	var max_per_battle: int = -1
	## ②′ 用的数值钩子：Callable(value: float) -> float。符文的加区/乘区走这里
	var value_hook: Callable = Callable()


var _listeners: Array = []           ## Array[Listener]，按 slot_order 升序
var _round_counts: Dictionary = {}   ## "uid:timing" -> int
var _battle_counts: Dictionary = {}
var _depth: int = 0


## 重建监听者缓存。loadout / 装备 / 状态变化时调用。
## sources 形如 [{uid, tag, slot_order, triggers:[...]}]
func rebuild_listeners(sources: Array) -> void:
	_listeners.clear()
	for s in sources:
		for t in s.get("triggers", []):
			var l := Listener.new()
			l.source_uid = s.get("uid", 0)
			l.source_tag = s.get("tag", "")
			l.slot_order = s.get("slot_order", 0)
			l.timing = t.get("when", 0)
			l.effects = t.get("effects", [])
			l.max_per_round = t.get("max_per_round", -1)
			l.max_per_battle = t.get("max_per_battle", -1)
			l.value_hook = t.get("value_hook", Callable())
			_listeners.append(l)
	# ⚠️ 唯一顺序来源：显式排序，同 slot_order 时用 uid tiebreak（确定性）
	_listeners.sort_custom(func(a: Listener, b: Listener) -> bool:
		if a.slot_order != b.slot_order:
			return a.slot_order < b.slot_order
		return a.source_uid < b.source_uid
	)


func reset_round_counters() -> void:
	_round_counts.clear()


func reset_battle_counters() -> void:
	_battle_counts.clear()
	_round_counts.clear()


func _count_key(l: Listener) -> String:
	return "%d:%d" % [l.source_uid, l.timing]


func _can_fire(l: Listener) -> bool:
	var key := _count_key(l)
	if l.max_per_round >= 0 and _round_counts.get(key, 0) >= l.max_per_round:
		return false
	if l.max_per_battle >= 0 and _battle_counts.get(key, 0) >= l.max_per_battle:
		return false
	return true


func _mark_fired(l: Listener) -> void:
	var key := _count_key(l)
	_round_counts[key] = _round_counts.get(key, 0) + 1
	_battle_counts[key] = _battle_counts.get(key, 0) + 1


## 分发一个时机。ctx 是纯数据上下文（source_id / target_id / tags 等）。
func emit(timing: int, ctx: Dictionary, state, q: ActionQueue) -> void:
	if _depth >= K.MAX_TRIGGER_DEPTH:
		state.rule_violations.append({
			"kind": "trigger_depth", "timing": timing, "depth": _depth,
			"round": state.round_number,
		})
		return

	# 保证 2：冻结列表
	var frozen: Array = _listeners.duplicate()
	_depth += 1
	var fired := 0

	for l in frozen:
		if l.timing != timing:
			continue
		if not _can_fire(l):
			continue
		# 保证 5：宽度闸
		if fired >= K.MAX_TRIGGERS_PER_EMIT:
			state.rule_violations.append({
				"kind": "trigger_width", "timing": timing,
				"limit": K.MAX_TRIGGERS_PER_EMIT, "round": state.round_number,
			})
			break
		_mark_fired(l)
		fired += 1
		state.log_event("rune_triggered", {"tag": l.source_tag, "timing": timing})
		# 把符文效果转成动作，用 push_next 插到当前动作之后（保持槽位顺序语义）
		for e in l.effects:
			var acts := _effect_to_actions(e, ctx, state)
			for a in acts:
				a.source_tag = l.source_tag
				q.push_next(a)

	_depth -= 1


## ②′ 的数值钩子链：按槽位顺序依次作用于 running value。
## 返回一个 Callable 供 DamageCalculator 调用。
##
## ⚠️ 这就是 §6.5「[锐化,倍化]=21 而 [倍化,锐化]=19」的实现处。
func make_value_hook(timing: int) -> Callable:
	var chain: Array = []
	for l in _listeners:
		if l.timing == timing and l.value_hook.is_valid() and _can_fire(l):
			chain.append(l)
	if chain.is_empty():
		return Callable()
	return func(v: float, log: Array) -> float:
		var cur := v
		for l in chain:
			var before := cur
			cur = l.value_hook.call(cur)
			log.append({"tag": l.source_tag, "slot": l.slot_order, "before": before, "after": cur})
		return cur


## EffectStep → GameAction。P1 只支持 P1 用到的 op，其余由 EffectExecutor 补。
func _effect_to_actions(e: EffectStep, ctx: Dictionary, state) -> Array:
	var out: Array = []
	var src_id: int = ctx.get("source_id", -1)
	var tgt_id: int = ctx.get("target_id", -1)
	match e.op:
		GameEnums.EffectOp.DEAL_DAMAGE:
			var src: Unit = state.unit_by_id(src_id)
			var tgt: Unit = state.unit_by_id(tgt_id)
			if src != null and tgt != null:
				var c := DamageCalculator.Context.new()
				c.source = src
				c.target = tgt
				c.flat = e.flat_value
				c.stat_ref = e.stat_ref
				c.stat_ratio = e.stat_ratio
				var r := DamageCalculator.calculate(c, state.rng)
				out.append(Actions.damage(src_id, tgt_id, r.to_dict()))
		GameEnums.EffectOp.GAIN_BLOCK:
			out.append(Actions.gain_block(src_id, int(e.value_for(state.unit_by_id(src_id)))))
		GameEnums.EffectOp.DRAW_CARD:
			out.append(Actions.draw(e.repeat))
		GameEnums.EffectOp.GAIN_ENERGY:
			out.append(Actions.gain_energy(int(e.value_for(null))))
		_:
			pass
	return out


func listener_count() -> int:
	return _listeners.size()


## 调试：完整触发链（服务 §13.3 的「符文实验室」，R8 的解药）
func describe_chain(timing: int) -> Array:
	var out: Array = []
	for l in _listeners:
		if l.timing == timing:
			out.append({"slot": l.slot_order, "tag": l.source_tag})
	return out
