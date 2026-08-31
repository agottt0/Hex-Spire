extends SceneTree
## 架构纪律静态检查 —— §12.1 的机械强制
##
## 这是全项目性价比最高的检查：因为代码由 AI 实现、用户只 review，
## 它把 review 从"逐行找 await"变成"看这个是不是绿的"。
##
## 独立可跑（不依赖 GUT）：
##   godot --headless --path E:/GameDemo -s res://tools/check_discipline.gd
## 退出码 0 = 全部通过，1 = 有违规。
##
## GUT 装好后 tests/test_architecture_discipline.gd 会复用同一份规则表。

const CORE_DIR := "res://src/core"
const SCENES_DIR := "res://src/scenes"

## core 里禁止出现的模式。每条 = [正则, 说明, 违反的纪律]
##
## ⚠️ RNG 相关规则用负向后视 (?<!\.) 排除带接收者的形式：
##   `randi()` 是全局调用 → 违规
##   `stream.randi_range()` 是注入流上的调用 → 合法
const CORE_FORBIDDEN := [
	["(?<![.\\w])randi\\s*\\(", "直接调用 randi()", "纪律1 注入式RNG"],
	["(?<![.\\w])randf\\s*\\(", "直接调用 randf()", "纪律1 注入式RNG"],
	["(?<![.\\w])randi_range\\s*\\(", "直接调用 randi_range()", "纪律1 注入式RNG"],
	["(?<![.\\w])randomize\\s*\\(", "调用 randomize()", "纪律1 注入式RNG"],
	# ⚠️ 只禁 `xxx.shuffle(` 且接收者不是 rng ——
	#   `rng.shuffle(arr, rng.deck)` 是注入式实现，合法。
	["(?<!rng)(?<!streams)\\.shuffle\\s*\\(", "Array.shuffle() 用全局RNG", "纪律1 注入式RNG"],
	["\\.pick_random\\s*\\(", "Array.pick_random() 用全局RNG", "纪律1 注入式RNG"],
	["\\bawait\\b", "core 里 await（逻辑不得等待动画）", "纪律3 表现层分离"],
	["get_tree\\s*\\(", "core 引用场景树", "纪律3 表现层分离"],
	["create_timer", "core 里用计时器", "纪律3 表现层分离"],
	["\\bEventBus\\b", "core 引用 EventBus autoload", "纪律3 表现层分离"],
	["\\bRNGService\\b", "core 引用 RNGService autoload", "纪律3 注入式RNG"],
	["(?<![.\\w])Database\\.", "core 引用 Database autoload", "纪律3 表现层分离"],
	["extends\\s+Node\\b", "core 继承 Node", "纪律3 表现层分离"],
	["extends\\s+Node2D\\b", "core 继承 Node2D", "纪律3 表现层分离"],
	["extends\\s+Control\\b", "core 继承 Control", "纪律3 表现层分离"],
	["Time\\.get_", "core 里读系统时间", "纪律5 确定性"],
	["OS\\.get_ticks", "core 里读 tick", "纪律5 确定性"],
	["Engine\\.get_frames", "core 里读帧数", "纪律5 确定性"],
	["DIRS\\s*\\[\\s*[a-z_]*facing", "直接用 DIRS[facing]（陷阱H1）—— 请用 HexCoord.facing_dir()", "陷阱H1"],
]

## 豁免：这些文件本身就是对应机制的实现处
## 格式：文件路径 -> 该文件豁免的规则说明关键词
const EXEMPTIONS := {
	"res://src/core/rng/rng_streams.gd": ["纪律1 注入式RNG"],
}

## 表现层禁止直改状态（纪律 2：所有状态变更经 ActionQueue）
const SCENES_FORBIDDEN := [
	["\\.hp\\s*(-|\\+)?=", "表现层直改 hp", "纪律2 ActionQueue"],
	["\\.block\\s*(-|\\+)?=", "表现层直改 block", "纪律2 ActionQueue"],
	["\\.energy\\s*(-|\\+)?=", "表现层直改 energy", "纪律2 ActionQueue"],
]

## TileMap 坐标转换只允许出现在这两个文件里
const MAP_CONV_PATTERN := "local_to_map|map_to_local|offset_to_map|map_to_offset|cube_to_map|map_to_cube"
const MAP_CONV_ALLOWED := [
	"res://src/core/hex/hex_coord.gd",
	"res://src/scenes/battle/hex_board_view.gd",
]

## GameRule 只允许在这几个文件里出现。
##
## 区分【声明】与【消费】：
##   · content_library / hero_data 只是把规则写进数据（声明"骑士有 BLOCK_PERSISTS"），
##     不读取当前有效值 → 允许
##   · 读取"当前生效的规则值"必须走 rule_book.gd 的消费函数 → 白名单外禁止
const GAMERULE_PATTERN := "GameRule\\.[A-Z_]+"
const GAMERULE_ALLOWED := [
	"res://src/core/enums.gd",
	"res://src/core/battle/rule_book.gd",
	"res://src/core/runes/rune_loadout.gd",
	"res://src/core/battle/content_library.gd",   # 声明数据，非消费
	"res://src/core/battle/hero_data.gd",         # 声明数据，非消费
]

## 额外强制：读取规则值只能走 RuleBook。
## 直接访问 state.rule_agg 就是绕过单消费点。
const RULE_AGG_PATTERN := "rule_agg\\s*[\\.\\[]"
const RULE_AGG_ALLOWED := [
	"res://src/core/battle/rule_book.gd",
	"res://src/core/battle/battle_state.gd",   # 定义与快照
	"res://src/core/battle/battle_setup.gd",   # 初始化赋值
	"res://src/core/runes/rune_loadout.gd",
]

var violations: Array[String] = []


func _initialize() -> void:
	print("=== 架构纪律检查（§12.1）===")
	print("")

	_check_dir(CORE_DIR, CORE_FORBIDDEN, "core")
	_check_dir(SCENES_DIR, SCENES_FORBIDDEN, "scenes")
	_check_whitelist(MAP_CONV_PATTERN, MAP_CONV_ALLOWED, "TileMap 坐标转换")
	_check_whitelist(GAMERULE_PATTERN, GAMERULE_ALLOWED, "GameRule 声明/消费")
	_check_whitelist(RULE_AGG_PATTERN, RULE_AGG_ALLOWED, "rule_agg 直接访问（应走 RuleBook）")

	print("")
	if violations.is_empty():
		print("✅ 全部通过（%d 个文件已扫描）" % _scanned)
		quit(0)
	else:
		print("❌ 发现 %d 处违规：" % violations.size())
		for v in violations:
			print("   " + v)
		quit(1)


var _scanned := 0


func _gd_files(root: String) -> Array[String]:
	var out: Array[String] = []
	_walk(root, out)
	out.sort()  # 确定性顺序
	return out


func _walk(path: String, acc: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		var full := path.path_join(f)
		if dir.current_is_dir():
			if not f.begins_with("."):
				_walk(full, acc)
		elif f.ends_with(".gd"):
			acc.append(full)
		f = dir.get_next()
	dir.list_dir_end()


## 去掉注释与字符串字面量，避免注释里提到 await 就误报
func _strip_noise(line: String) -> String:
	var s := line
	var hash_pos := s.find("#")
	if hash_pos >= 0:
		s = s.substr(0, hash_pos)
	# 粗暴去掉双引号字符串内容
	var re := RegEx.create_from_string("\"[^\"]*\"")
	s = re.sub(s, "\"\"", true)
	return s


func _check_dir(root: String, rules: Array, label: String) -> void:
	var files := _gd_files(root)
	_scanned += files.size()
	var hits := 0
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		if text == "":
			continue
		var exempt: Array = EXEMPTIONS.get(path, [])
		var lines := text.split("\n")
		for i in range(lines.size()):
			var clean := _strip_noise(lines[i])
			if clean.strip_edges() == "":
				continue
			for rule in rules:
				if rule[2] in exempt:
					continue
				var re := RegEx.create_from_string(rule[0])
				if re.search(clean) != null:
					violations.append("%s:%d  %s  [%s]" % [path, i + 1, rule[1], rule[2]])
					hits += 1
	print("[%s] 扫描 %d 个文件，违规 %d 处" % [label, files.size(), hits])


func _check_whitelist(pattern: String, allowed: Array, label: String) -> void:
	var files := _gd_files("res://src")
	var re := RegEx.create_from_string(pattern)
	var hits := 0
	for path in files:
		if path in allowed:
			continue
		var text := FileAccess.get_file_as_string(path)
		if text == "":
			continue
		var lines := text.split("\n")
		for i in range(lines.size()):
			var clean := _strip_noise(lines[i])
			if re.search(clean) != null:
				violations.append("%s:%d  %s 只允许出现在 %s" % [path, i + 1, label, str(allowed)])
				hits += 1
	print("[白名单] %s：越界 %d 处" % [label, hits])
