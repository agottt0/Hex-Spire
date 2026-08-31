class_name CardInstance
extends RefCounted
## 卡牌【实例】—— 区别于 CardData（定义）
##
## 为什么需要实例：同一张 CardData 在卡组里可以有多份（max_copies_in_deck），
## 各自可能有不同的升级状态、临时费用修正。牌堆操作必须按实例而非定义来做，
## 否则"弃掉一张《攻击》"会分不清弃的是哪一张。

static var _next_uid: int = 1

var uid: int = 0
var data: CardData = null
var upgraded: bool = false
## 本场战斗内的临时费用修正（某些符文/状态会改单卡费用）
var temp_cost_delta: int = 0


func _init(p_data: CardData = null) -> void:
	data = p_data
	uid = _next_uid
	_next_uid += 1


## ⚠️ 测试与 battle_sim 必须能重置 uid，否则跑多场后 uid 递增，
##    action_log 的哈希会因 uid 不同而不一致 → 确定性验证误报。
static func reset_uid_counter() -> void:
	_next_uid = 1


func base_cost() -> int:
	return (data.energy_cost if data != null else 0) + temp_cost_delta


func card_id() -> String:
	return data.id if data != null else ""


func display_name() -> String:
	if data == null:
		return "?"
	return data.display_name + ("+" if upgraded else "")


func to_dict() -> Dictionary:
	return {"uid": uid, "id": card_id(), "up": upgraded, "dcost": temp_cost_delta}
