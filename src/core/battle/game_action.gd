class_name GameAction
extends RefCounted
## 所有状态变更的载体 —— 架构纪律 2（§12.1）
##
## ❌ 禁止：target.hp -= 20
## ✅ 必须：queue.push_back(Actions.damage(src, tgt, packet))
##
## 设计选择：**扁平数据 + 处理器注册表**，而不是子类多态。
##   好处：to_dict/from_dict 各两行 → 动作日志天然是 JSON，
##         战报、bug 复现、Undo、（未来的）联机广播全部免费。
##   代价：字段没有静态类型 → 用 actions.gd 的命名构造器补偿。
##
## ⚠️ data 里只允许放可序列化的纯值：
##   int / float / bool / String / Vector2i / Vector3i / Array / Dictionary
##   禁止放 Unit / Resource 等对象引用 —— 用 unit_id / resource id 代替。

var type: StringName = &""
var data: Dictionary = {}

## 由 ActionQueue 填写，用于调试与递归深度追踪
var depth: int = 0
## 触发来源描述（"card:atk_basic" / "rune:slot3" / "status:burn"），仅用于日志
var source_tag: String = ""


func _init(p_type: StringName = &"", p_data: Dictionary = {}) -> void:
	type = p_type
	data = p_data


func to_dict() -> Dictionary:
	return {"t": String(type), "d": data, "src": source_tag}


static func from_dict(d: Dictionary) -> GameAction:
	var a := GameAction.new()
	a.type = StringName(d.get("t", ""))
	a.data = d.get("d", {})
	a.source_tag = d.get("src", "")
	return a


func _to_string() -> String:
	return "[%s %s]" % [type, data]
