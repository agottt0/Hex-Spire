class_name ActionQueue
extends RefCounted
## 所有状态变更的唯一入口 —— 架构纪律 2（§12.1 原文："这是 5 条里最关键的一条"）
##
## 两种入队方式的区别很重要：
##   push_back  —— 排到队尾（普通排队）
##   push_next  —— 插到【当前动作之后】
##
## ⚠️ push_next 是必须的：符文触发产生的子动作要在触发它的动作【之后立刻】结算，
##    而不是排到队尾。否则 §6.5 的"槽位 1→6 顺序"语义会被打乱 ——
##    槽 1 的子动作会跑到槽 6 的主动作后面去。
##
## R7 安全闸（策划案 §16.1）：递归深度与动作总数双上限，
## 超限时【写 rule_violations 并中止，绝不抛异常】。
## battle_sim 靠这个把死循环变成可统计数据。

var _queue: Array[GameAction] = []
var _insert_pos: int = -1        ## push_next 的插入位置
var depth: int = 0

## 本次 resolve_all 已执行的动作数
var _resolved_count: int = 0

## 解析器（由 BattleState 注入，避免循环依赖）
var resolver = null


func push_back(a: GameAction) -> void:
	a.depth = depth
	_queue.append(a)


## 插到当前动作之后（子动作，深度优先语义）
func push_next(a: GameAction) -> void:
	a.depth = depth + 1
	if _insert_pos < 0 or _insert_pos > _queue.size():
		_queue.append(a)
	else:
		_queue.insert(_insert_pos, a)
		_insert_pos += 1


func push_many(list: Array) -> void:
	for a in list:
		push_back(a)


func is_empty() -> bool:
	return _queue.is_empty()


func size() -> int:
	return _queue.size()


func clear() -> void:
	_queue.clear()
	_insert_pos = -1
	depth = 0
	_resolved_count = 0


## 循环执行到队列为空。
##
## 返回执行的动作数。超限时在 state.rule_violations 追加记录并中止。
func resolve_all(state) -> int:
	_resolved_count = 0
	while not _queue.is_empty():
		if _resolved_count >= K.MAX_ACTIONS_PER_RESOLVE:
			state.rule_violations.append({
				"kind": "action_overflow",
				"limit": K.MAX_ACTIONS_PER_RESOLVE,
				"remaining": _queue.size(),
				"round": state.round_number,
			})
			# ⚠️ 不抛异常：让 battle_sim 能统计而非崩溃
			_queue.clear()
			break

		var a: GameAction = _queue.pop_front()
		depth = a.depth

		if a.depth >= K.MAX_TRIGGER_DEPTH:
			state.rule_violations.append({
				"kind": "depth_overflow",
				"limit": K.MAX_TRIGGER_DEPTH,
				"action": String(a.type),
				"src": a.source_tag,
				"round": state.round_number,
			})
			continue

		# 记录插入锚点：本动作产生的子动作插到它后面
		_insert_pos = 0
		if resolver != null:
			resolver.execute(a, state, self)
		_insert_pos = -1
		_resolved_count += 1

	depth = 0
	return _resolved_count


func resolved_count() -> int:
	return _resolved_count
