extends Node
## 启动时扫描 data/ 并索引所有 Resource —— §14.1
##
## 数据驱动架构（§15.4 / R10 的唯一解）：新增一张卡 = 新增一个 .tres 文件，
## 不改代码。本文件负责把它们找出来并按 id 建索引。
##
## ⚠️ src/core/ 不引用本文件。core 接收已加载好的 Resource 实例。
##   battle_sim 用 ResourceLoader.load() 自己加载，不依赖本 autoload。

const DATA_DIRS := {
	"heroes": "res://data/heroes",
	"cards": "res://data/cards",
	"runes": "res://data/runes",
	"equipment": "res://data/equipment",
	"enemies": "res://data/enemies",
	"encounters": "res://data/encounters",
	"statuses": "res://data/statuses",
	"room_layouts": "res://data/room_layouts",
	"loot_tables": "res://data/loot_tables",
	"events": "res://data/events",
}

## category -> { id -> Resource }
var _index: Dictionary = {}


func _ready() -> void:
	reload_all()


func reload_all() -> void:
	_index.clear()
	for category in DATA_DIRS:
		_index[category] = _scan_dir(DATA_DIRS[category])
	var total := 0
	for c in _index:
		total += (_index[c] as Dictionary).size()
	print("[Database] 已加载 %d 个资源，分布：%s" % [total, _counts()])


func _counts() -> Dictionary:
	var out := {}
	for c in _index:
		var n: int = (_index[c] as Dictionary).size()
		if n > 0:
			out[c] = n
	return out


func _scan_dir(path: String) -> Dictionary:
	var out := {}
	if not DirAccess.dir_exists_absolute(path):
		return out
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and (fname.ends_with(".tres") or fname.ends_with(".res")):
			var res := ResourceLoader.load(path.path_join(fname))
			if res != null:
				var rid: String = res.get("id") if "id" in res else ""
				if rid == "":
					rid = fname.get_basename()
					push_warning("[Database] %s 缺少 id 字段，回退用文件名 '%s'" % [fname, rid])
				if out.has(rid):
					push_error("[Database] id 重复：'%s'（%s）" % [rid, fname])
				out[rid] = res
		fname = dir.get_next()
	dir.list_dir_end()
	return out


# ------------------------------------------------------------------ 查询

func get_res(category: String, id: String) -> Resource:
	var cat: Dictionary = _index.get(category, {})
	if not cat.has(id):
		push_error("[Database] 找不到 %s/%s" % [category, id])
		return null
	return cat[id]


func get_all(category: String) -> Array:
	var cat: Dictionary = _index.get(category, {})
	# ⚠️ 返回按 id 排序的数组，而非 Dictionary.values() ——
	#    纪律 5 禁止依赖 Dictionary 遍历顺序做逻辑判断
	var ids: Array = cat.keys()
	ids.sort()
	var out: Array = []
	for i in ids:
		out.append(cat[i])
	return out


func has_res(category: String, id: String) -> bool:
	return (_index.get(category, {}) as Dictionary).has(id)


func hero(id: String) -> Resource:
	return get_res("heroes", id)


func card(id: String) -> Resource:
	return get_res("cards", id)


func enemy(id: String) -> Resource:
	return get_res("enemies", id)
