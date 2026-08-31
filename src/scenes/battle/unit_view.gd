extends Node2D
class_name UnitView
## 单位的灰盒表现 —— 零美术资产
##
## §13.2 的三条硬要求都在这里：
##   1. footprint 完整描边（不只画锚点格）
##   2. 每个占用格都有接地阴影 —— 3/4 视角下判断"站在哪"的唯一可靠线索
##   3. 朝向指示（走 HexCoord.facing_dir，陷阱 H1）
##
## 己方/敌方用【轮廓光颜色】区分而非底座圆环 ——
## 底座会与 HighlightLayer 抢视觉（美术文档 R6）

const COLOR_PLAYER := Color("#4A78C8")
const COLOR_ENEMY := Color("#C84A4A")
const COLOR_ELITE := Color("#9B4AC8")
const COLOR_BOSS := Color("#C87A2A")
const OUTLINE_PLAYER := Color("#3DD6D0")
const OUTLINE_ENEMY := Color("#FF3B30")

var unit_id: int = -1
var board: HexBoardView = null

# 从 BattleState 同步来的显示数据（表现层不持有 Unit 引用 —— 纪律 3）
var cells_offset: Array = []      ## [[col,row], ...]
var anchor_offset := Vector2i(4, 1)
var facing: int = 2
var team: int = 0
var is_elite := false
var is_boss := false
var display_name := ""
var hp: int = 1
var hp_max: int = 1
var block: int = 0
var size_class: int = 0
var intent_text := ""

var _label: Label
var _intent_label: Label


func _ready() -> void:
	_label = Label.new()
	_label.z_index = 20
	_label.add_theme_font_size_override("font_size", 15)
	add_child(_label)
	_intent_label = Label.new()
	_intent_label.z_index = 20
	_intent_label.add_theme_font_size_override("font_size", 14)
	_intent_label.add_theme_color_override("font_color", OUTLINE_ENEMY)
	add_child(_intent_label)


func sync_from(d: Dictionary, p_board: HexBoardView) -> void:
	board = p_board
	unit_id = d.get("id", -1)
	display_name = d.get("name", "")
	team = d.get("team", 0)
	anchor_offset = Vector2i(d.get("col", 1), d.get("row", 1))
	facing = d.get("facing", 0)
	hp = d.get("hp", 1)
	hp_max = d.get("hp_max", 1)
	block = d.get("block", 0)
	size_class = d.get("size", 0)
	is_elite = d.get("elite", false)
	is_boss = d.get("boss", false)
	cells_offset = d.get("cells", [])
	_update_labels()
	queue_redraw()


func _update_labels() -> void:
	if _label == null:
		return
	var blk := ("  🛡%d" % block) if block > 0 else ""
	var sz: String = ["S", "M", "L"][clampi(size_class, 0, 2)]
	_label.text = "%s[%s] %d/%d%s" % [display_name, sz, hp, hp_max, blk]
	var p := board.world_pos_of(anchor_offset.x, anchor_offset.y) if board != null else Vector2.ZERO
	_label.position = p + Vector2(-52, -float(K.TILE_H) * 0.55)
	_intent_label.text = intent_text
	_intent_label.position = p + Vector2(-40, -float(K.TILE_H) * 0.55 - 20)


func body_color() -> Color:
	if team == int(GameEnums.Team.PLAYER):
		return COLOR_PLAYER
	if is_boss:
		return COLOR_BOSS
	if is_elite:
		return COLOR_ELITE
	return COLOR_ENEMY


func outline_color() -> Color:
	return OUTLINE_PLAYER if team == int(GameEnums.Team.PLAYER) else OUTLINE_ENEMY


func _draw() -> void:
	if board == null or cells_offset.is_empty():
		return

	# ── 1. 接地阴影（每个占用格都画 —— §13.2 硬要求）
	for cell in cells_offset:
		var p: Vector2 = board.world_pos_of(cell[0], cell[1])
		draw_set_transform(p + Vector2(0, float(K.TILE_H) * 0.22), 0.0, Vector2(1.0, 0.42))
		draw_circle(Vector2.ZERO, float(K.TILE_W) * 0.30, Color(0, 0, 0, 0.40))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# ── 2. 本体
	var bc := body_color()
	if cells_offset.size() == 1:
		# S：圆形
		var p0: Vector2 = board.world_pos_of(cells_offset[0][0], cells_offset[0][1])
		draw_circle(p0, float(K.TILE_W) * 0.30, bc)
		draw_arc(p0, float(K.TILE_W) * 0.30, 0, TAU, 32, outline_color(), 3.0, true)
	else:
		# M/L：填充所有占格 + 完整边界描边
		for cell in cells_offset:
			var poly := board.hex_points(cell[0], cell[1])
			var shrunk := _shrink(poly, 0.82)
			draw_colored_polygon(shrunk, bc * Color(1, 1, 1, 0.9))
		_draw_footprint_outline()

	# ── 3. 朝向指示（走 facing_dir —— 陷阱 H1）
	var ap: Vector2 = board.world_pos_of(anchor_offset.x, anchor_offset.y)
	var fd := HexCoord.facing_dir(facing)
	var anchor_cube := HexCoord.offset_to_cube(anchor_offset.x, anchor_offset.y)
	var target := board.world_pos_of_cube(anchor_cube + fd)
	var dir := (target - ap).normalized()
	draw_line(ap, ap + dir * float(K.TILE_W) * 0.38, outline_color(), 5.0, true)
	# 小三角箭头
	var tip := ap + dir * float(K.TILE_W) * 0.46
	var perp := Vector2(-dir.y, dir.x) * 7.0
	draw_colored_polygon(PackedVector2Array([tip, tip - dir * 12.0 + perp,
		tip - dir * 12.0 - perp]), outline_color())

	# ── 4. HP 条
	_draw_hp_bar(ap)


## footprint 边界描边：只画外边，内部共享边丢弃（§13.2）
func _draw_footprint_outline() -> void:
	# 收集所有边，count==1 的是边界
	var edge_count := {}
	var edge_pts := {}
	for cell in cells_offset:
		var poly := board.hex_points(cell[0], cell[1])
		for i in range(6):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % 6]
			var key := _edge_key(a, b)
			edge_count[key] = edge_count.get(key, 0) + 1
			edge_pts[key] = [a, b]
	# 确定性顺序
	var keys: Array = edge_count.keys()
	keys.sort()
	for k in keys:
		if edge_count[k] == 1:
			var pair: Array = edge_pts[k]
			draw_line(pair[0], pair[1], outline_color(), 4.0, true)


static func _edge_key(a: Vector2, b: Vector2) -> String:
	# 端点无序化 + 量化，让相邻格共享的边得到同一个键
	var pa := Vector2i(roundi(a.x), roundi(a.y))
	var pb := Vector2i(roundi(b.x), roundi(b.y))
	if pa.x > pb.x or (pa.x == pb.x and pa.y > pb.y):
		var t := pa
		pa = pb
		pb = t
	return "%d,%d-%d,%d" % [pa.x, pa.y, pb.x, pb.y]


static func _shrink(poly: PackedVector2Array, factor: float) -> PackedVector2Array:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= float(poly.size())
	var out := PackedVector2Array()
	for p in poly:
		out.append(c + (p - c) * factor)
	return out


func _draw_hp_bar(center: Vector2) -> void:
	var w := float(K.TILE_W) * 0.62
	var h := 7.0
	var top_left := center + Vector2(-w * 0.5, float(K.TILE_H) * 0.30)
	draw_rect(Rect2(top_left, Vector2(w, h)), Color(0.06, 0.06, 0.08, 0.9))
	var ratio := clampf(float(hp) / float(maxi(1, hp_max)), 0.0, 1.0)
	var fill := Color("#5FD16A") if team == int(GameEnums.Team.PLAYER) else Color("#D15F5F")
	draw_rect(Rect2(top_left, Vector2(w * ratio, h)), fill)
	# 格挡叠在血条上方
	if block > 0:
		var bw := minf(w, w * float(block) / float(maxi(1, hp_max)))
		draw_rect(Rect2(top_left + Vector2(0, -h - 1.5), Vector2(bw, h)), Color("#7FA8D9"))
	draw_rect(Rect2(top_left, Vector2(w, h)), Color(0, 0, 0, 0.55), false, 1.5)
