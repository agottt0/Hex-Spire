extends Node
## 全局事件总线 —— 架构纪律 3（§12.1）
##
## ⚠️ src/core/ 【禁止】引用本文件。
##   core 不 emit 信号，而是往 BattleState.event_log 追加纯数据；
##   battle_scene.gd 每帧 drain 并转发到这里。
##   这样 core 可以在无渲染下跑完（battle_sim 与全部单测的前提），
##   纪律 3 是字面成立的，不靠自觉。

# ---- 战斗流程
signal battle_started(payload: Dictionary)
signal round_started(payload: Dictionary)
signal phase_changed(payload: Dictionary)
signal battle_ended(payload: Dictionary)

# ---- 单位
signal unit_spawned(payload: Dictionary)
signal unit_moved(payload: Dictionary)
signal unit_rotated(payload: Dictionary)
signal unit_died(payload: Dictionary)
signal damage_dealt(payload: Dictionary)
signal block_gained(payload: Dictionary)
signal healed(payload: Dictionary)
signal status_applied(payload: Dictionary)
signal status_removed(payload: Dictionary)

# ---- 卡牌
signal card_drawn(payload: Dictionary)
signal card_played(payload: Dictionary)
signal card_discarded(payload: Dictionary)
signal card_exhausted(payload: Dictionary)
signal deck_reshuffled(payload: Dictionary)
signal energy_changed(payload: Dictionary)

# ---- 符文
signal rune_triggered(payload: Dictionary)

# ---- 意图
signal intent_updated(payload: Dictionary)

# ---- UI 请求（表现层 → 表现层，不进 core）
signal ui_card_selected(card_uid: int)
signal ui_selection_cancelled()
signal ui_undo_requested()

## 把 core 产出的纯数据事件转发成信号。
## event 形如 {"t": "damage_dealt", "d": {...}}
func dispatch(event: Dictionary) -> void:
	var t: String = event.get("t", "")
	var d: Dictionary = event.get("d", {})
	match t:
		"battle_started": battle_started.emit(d)
		"round_started": round_started.emit(d)
		"phase_changed": phase_changed.emit(d)
		"battle_ended": battle_ended.emit(d)
		"unit_spawned": unit_spawned.emit(d)
		"unit_moved": unit_moved.emit(d)
		"unit_rotated": unit_rotated.emit(d)
		"unit_died": unit_died.emit(d)
		"damage_dealt": damage_dealt.emit(d)
		"block_gained": block_gained.emit(d)
		"healed": healed.emit(d)
		"status_applied": status_applied.emit(d)
		"status_removed": status_removed.emit(d)
		"card_drawn": card_drawn.emit(d)
		"card_played": card_played.emit(d)
		"card_discarded": card_discarded.emit(d)
		"card_exhausted": card_exhausted.emit(d)
		"deck_reshuffled": deck_reshuffled.emit(d)
		"energy_changed": energy_changed.emit(d)
		"rune_triggered": rune_triggered.emit(d)
		"intent_updated": intent_updated.emit(d)
		_:
			push_warning("EventBus.dispatch: 未知事件类型 '%s'" % t)
