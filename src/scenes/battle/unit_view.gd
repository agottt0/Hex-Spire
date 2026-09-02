extends Node2D
class_name UnitView
## 单位表现层 —— 有美术资产时叠加角色动画，没有则回退灰盒
##
## §13.2 的三条硬要求【无论走哪条路径都必须成立】：
##   1. footprint 完整描边（不只画锚点格）
##   2. 每个占用格都有接地阴影 —— 3/4 视角下判断"站在哪"的唯一可靠线索
##   3. 朝向指示（走 HexCoord.facing_dir，陷阱 H1）
##
## 己方/敌方用【轮廓光颜色】区分而非底座圆环 ——
## 底座会与 HighlightLayer 抢视觉（美术文档 R6）
##
## ── 接美术后为什么这三条一条都不能删 ──────────────────────────────
## 角色 sprite 只覆盖"身体"，它无法表达"我占哪几格"。M/L 单位若只有立绘，
## 玩家立刻会误判走位合法性（美术文档 §8.2 把描边与每格接地阴影列为
## 「三条不可省略的实现要求」）。所以 sprite 是【叠加】而非【替换】：
##   地面层（阴影 + 淡填充 + 描边）→ 角色 sprite → HP 条 / 标签
##
## sprite 的 position 就是【脚底锚点】，与接地阴影中心同一点，
## 这样"人站在哪一格"与"阴影在哪一格"永远一致。

const COLOR_PLAYER := Color("#4A78C8")
const COLOR_ENEMY := Color("#C84A4A")
const COLOR_ELITE := Color("#9B4AC8")
const COLOR_BOSS := Color("#C87A2A")
const OUTLINE_PLAYER := Color("#3DD6D0")
const OUTLINE_ENEMY := Color("#FF3B30")

## sprite 高度目标，单位 = 格高（美术文档 §8.2）：
##   1 格 ≈1.6 格高（直立人形）/ 3 格 ≈2.2（非人比例）/ 6 格 ≈3.5（建筑尺度）
const SIZE_TARGET_H: Array[float] = [1.60, 2.20, 3.50]

## 脚底相对格中心的下移量。与接地阴影中心用同一个系数，两者必须一致。
const FOOT_OFFSET_RATIO := 0.22

## 原始素材面朝右侧；朝向指向屏幕左侧时水平翻转。
## 若某批资产实际朝左，改这一个常量即可。
const SPRITE_FACES_RIGHT := true

## 有 sprite 时，地面填充降到这个 alpha —— 仍能读出占位，又不与角色抢视觉
const FILL_ALPHA_WITH_ART := 0.26

## 一次性动画（attack）之后回到 idle 的兜底时长；move 反馈的持续时长
const MOVE_FEEDBACK_TIME := 0.34
## 受击闪红时长
const HURT_FLASH_TIME := 0.18

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
var source_id := ""
var hp: int = 1
var hp_max: int = 1
var block: int = 0
var size_class: int = 0
var intent_text := ""

var _label: Label
var _intent_label: Label

# ---- 美术层
var _sprite: AnimatedSprite2D = null
var _has_art := false
var _art_ready := false           ## 已尝试装配（无论成败），避免每帧重试
var _canvas := Vector2i.ZERO
var _move_timer := 0.0
var _hurt_timer := 0.0
var _prev_anchor := Vector2i(-999, -999)
var _prev_hp := -1


func _ready() -> void:
	# 只有装配了 sprite 的单位才需要每帧计时（灰盒单位零开销）
	set_process(false)
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
	source_id = d.get("source_id", "")
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

	_ensure_art()
	_detect_transitions()
	_update_sprite_transform()
	_update_labels()
	_update_depth()
	queue_redraw()


## 俯视角深度：row 越小（越靠画面下方 / 越靠前）越晚绘制。
## 多格单位取 footprint 里 row 最小的格作为基准（策划案 §14.3 原文要求）。
func _update_depth() -> void:
	var min_row := anchor_offset.y
	for cell in cells_offset:
		min_row = mini(min_row, int(cell[1]))
	z_index = HexCoord.ROWS - min_row


# ══════════════════════════════════════════════════════ 美术层

## 懒装配：sync_from 才知道 source_id，且只尝试一次。
## 无资产的单位（stone_golem / siege_worm）在此静默走灰盒。
func _ensure_art() -> void:
	if _art_ready or source_id == "":
		return
	_art_ready = true
	if not UnitSprites.has_art(source_id):
		return
	var sf := UnitSprites.frames_for(source_id)
	if sf == null:
		return
	_canvas = UnitSprites.canvas_size(source_id)
	if _canvas.x <= 0 or _canvas.y <= 0:
		return

	_sprite = AnimatedSprite2D.new()
	_sprite.sprite_frames = sf
	# centered=false + offset 把 position 定义成【画布底边中心】= 脚底锚点
	_sprite.centered = false
	_sprite.offset = Vector2(-float(_canvas.x) * 0.5, -float(_canvas.y))
	_sprite.z_index = 1          # 压在地面层（阴影/填充/描边）之上
	_sprite.animation_finished.connect(_on_anim_finished)
	add_child(_sprite)
	_sprite.play("idle")
	_has_art = true
	set_process(true)


## 从两次同步之间的差量推出该播什么。
## ⚠️ 逻辑层是瞬时结算的（无动画时序），所以这里只做"刚刚发生过什么"的事后反馈，
##    不试图把动画插回逻辑时间线 —— 那需要改事件回放架构（架构文档 §1）。
func _detect_transitions() -> void:
	if not _has_art:
		_prev_anchor = anchor_offset
		_prev_hp = hp
		return

	if _prev_anchor.x != -999 and _prev_anchor != anchor_offset:
		_move_timer = MOVE_FEEDBACK_TIME
		if _sprite.animation != "attack":
			_sprite.play("move")

	if _prev_hp >= 0 and hp < _prev_hp:
		_hurt_timer = HURT_FLASH_TIME

	_prev_anchor = anchor_offset
	_prev_hp = hp


## 外部触发的一次性攻击动画（由 battle_scene 在出牌/敌人行动后调用）
func play_attack() -> void:
	if not _has_art:
		return
	_move_timer = 0.0
	_sprite.play("attack")


func _on_anim_finished() -> void:
	# attack 不循环，播完必须回 idle，否则会停在最后一帧
	if _has_art and _sprite.animation == "attack":
		_sprite.play("idle")


func _process(delta: float) -> void:
	if not _has_art:
		return
	if _move_timer > 0.0:
		_move_timer -= delta
		if _move_timer <= 0.0 and _sprite.animation == "move":
			_sprite.play("idle")
	if _hurt_timer > 0.0:
		_hurt_timer -= delta
		var t := clampf(_hurt_timer / HURT_FLASH_TIME, 0.0, 1.0)
		_sprite.modulate = Color(1.0, 1.0 - 0.65 * t, 1.0 - 0.65 * t)
	elif _sprite.modulate != Color.WHITE:
		_sprite.modulate = Color.WHITE


## footprint 的几何中心（世界坐标）。
##
## ⚠️ 多格单位的 sprite 必须按【占位中心】而非【锚点】定位。
##   锚点只是 footprint 数组的原点，对 M(3格) 来说它在三角形的一个角上 ——
##   角色会明显偏在占位的一侧，玩家读不出"这只怪覆盖了这三格"（实测巨人偏右下）。
##   S 单位只有一格，中心 == 锚点，此改动对其无影响。
func _footprint_center() -> Vector2:
	if board == null:
		return Vector2.ZERO
	if cells_offset.is_empty():
		return board.world_pos_of(anchor_offset.x, anchor_offset.y)
	var sum := Vector2.ZERO
	for cell in cells_offset:
		sum += board.world_pos_of(cell[0], cell[1])
	return sum / float(cells_offset.size())


func _update_sprite_transform() -> void:
	if not _has_art or board == null:
		return
	# 脚底锚点：贴合占位中心，与该处的接地阴影同一水平线
	var p := _footprint_center()
	# 透视下"下移半格"的像素量本身也要随深度收缩，否则远处的脚会陷进地面
	var ds := _depth_scale()
	_sprite.position = p + Vector2(0, float(K.TILE_H) * FOOT_OFFSET_RATIO * ds)

	# ⚠️ 尺寸必须乘深度缩放，否则远处单位显得悬浮／过大，透视立刻穿帮
	var target_h := SIZE_TARGET_H[clampi(size_class, 0, 2)] * float(K.TILE_H) * ds
	var s := target_h / float(maxi(1, _canvas.y))
	_sprite.scale = Vector2(s, s)

	# 朝向：把立方方向投到屏幕，看水平分量。facing 必须走 facing_dir（陷阱 H1）
	var ap := board.world_pos_of(anchor_offset.x, anchor_offset.y)
	var cube := HexCoord.offset_to_cube(anchor_offset.x, anchor_offset.y)
	var screen_dir := board.world_pos_of_cube(cube + HexCoord.facing_dir(facing)) - ap
	if absf(screen_dir.x) > 0.5:
		var faces_left := screen_dir.x < 0.0
		_sprite.flip_h = faces_left if SPRITE_FACES_RIGHT else not faces_left


## 本单位所在处的深度缩放。取锚点格，保证与 HP 条／标签一致。
##
## 走 unit_depth_scale_at（弱化版）而非 depth_scale_at：
## 地面走满透视、角色欠透视，否则远处敌人缩到 50%、意图图标读不出来。
func _depth_scale() -> float:
	if board == null:
		return 1.0
	return board.unit_depth_scale_at(anchor_offset.x, anchor_offset.y)


func _update_labels() -> void:
	if _label == null:
		return
	var blk := ("  🛡%d" % block) if block > 0 else ""
	var sz: String = ["S", "M", "L"][clampi(size_class, 0, 2)]
	_label.text = "%s[%s] %d/%d%s" % [display_name, sz, hp, hp_max, blk]
	# 有 sprite 时标签跟随占位中心（与 sprite 同一基准），否则沿用锚点
	var p := Vector2.ZERO
	if board != null:
		p = _footprint_center() if _has_art else board.world_pos_of(anchor_offset.x, anchor_offset.y)

	# ⚠️ 有 sprite 时标签必须升到【头顶之上】。
	#   灰盒期 -0.55 格高刚好在圆形上方，但角色 sprite 高达 1.6–3.5 格，
	#   沿用旧偏移会把血量文字压在角色胸口 —— 既挡画面又读不清（实测踩过）。
	#   sprite.scale 已含深度缩放，所以有 sprite 那条分支自然跟着透视走。
	var ds := _depth_scale()
	var lift := float(K.TILE_H) * 0.55 * ds
	if _has_art:
		lift = float(_canvas.y) * _sprite.scale.y \
			- float(K.TILE_H) * FOOT_OFFSET_RATIO * ds + 6.0
	_label.position = p + Vector2(-52 * ds, -lift)
	_intent_label.text = intent_text
	_intent_label.position = p + Vector2(-40 * ds, -lift - 20)


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
	#
	# ⚠️ 旧实现是 draw_set_transform(scale(1, 0.42)) —— 那个 0.42 是【假透视】：
	#   一个写死的压扁比，在真投影下会与格子形状打架（远近压扁程度本应不同）。
	#   现在直接用投影后的六边形按比例内缩当阴影，形状天然与地砖一致。
	for cell in cells_offset:
		var hex := board.hex_points(cell[0], cell[1])
		draw_colored_polygon(_shrink(hex, 0.62), Color(0, 0, 0, 0.40))

	# ── 2. 本体 / 占位指示
	#    有 sprite 时这一层降级为【占位指示】：角色画身体，地面画"占哪几格"。
	#    描边一律保留 —— 它是玩家判断走位合法性的唯一依据（美术文档 §8.2），
	#    且走 hex_points 天然贴合格子透视，与接地阴影形状一致。
	var bc := body_color()
	if _has_art:
		for cell in cells_offset:
			var poly := board.hex_points(cell[0], cell[1])
			draw_colored_polygon(_shrink(poly, 0.82), Color(bc, FILL_ALPHA_WITH_ART))
		_draw_footprint_outline()
	elif cells_offset.size() == 1:
		# S 灰盒：贴合投影格形的多边形（不再用正圆 —— 透视下会不贴地）
		var solo := board.hex_points(cells_offset[0][0], cells_offset[0][1])
		draw_colored_polygon(_shrink(solo, 0.66), bc)
		draw_polyline(_closed(_shrink(solo, 0.66)), outline_color(), 3.0, true)
	else:
		# M/L 灰盒：填充所有占格 + 完整边界描边
		for cell in cells_offset:
			var poly := board.hex_points(cell[0], cell[1])
			draw_colored_polygon(_shrink(poly, 0.82), Color(bc, 0.9))
		_draw_footprint_outline()

	# ── 3. 朝向指示（走 facing_dir —— 陷阱 H1）
	#    长度与线宽按深度缩放，远处不至于比格子还长
	var ap: Vector2 = board.world_pos_of(anchor_offset.x, anchor_offset.y)
	var ds := _depth_scale()
	var origin := ap
	if _has_art:
		origin = ap + Vector2(0, float(K.TILE_H) * FOOT_OFFSET_RATIO * ds)
	var fd := HexCoord.facing_dir(facing)
	var anchor_cube := HexCoord.offset_to_cube(anchor_offset.x, anchor_offset.y)
	var target := board.world_pos_of_cube(anchor_cube + fd)
	var dir := (target - ap).normalized()
	draw_line(origin, origin + dir * float(K.TILE_W) * 0.38 * ds,
		outline_color(), maxf(2.0, 5.0 * ds), true)
	# 小三角箭头
	var tip := origin + dir * float(K.TILE_W) * 0.46 * ds
	var perp := Vector2(-dir.y, dir.x) * 7.0 * ds
	draw_colored_polygon(PackedVector2Array([tip,
		tip - dir * 12.0 * ds + perp,
		tip - dir * 12.0 * ds - perp]), outline_color())

	# ── 4. HP 条
	_draw_hp_bar(ap, ds)


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


## 收尾成闭合折线（描边用）
static func _closed(poly: PackedVector2Array) -> PackedVector2Array:
	var out := poly.duplicate()
	if out.size() > 0:
		out.append(out[0])
	return out


## HP 条。宽度随深度缩放，但【高度设下限】——
## 血条是关键信息，远处也必须能读出（美术文档 V3 优先于透视一致性）。
func _draw_hp_bar(center: Vector2, ds: float) -> void:
	var w := float(K.TILE_W) * 0.62 * ds
	var h := maxf(4.0, 7.0 * ds)
	var top_left := center + Vector2(-w * 0.5, float(K.TILE_H) * 0.30 * ds)
	draw_rect(Rect2(top_left, Vector2(w, h)), Color(0.06, 0.06, 0.08, 0.9))
	var ratio := clampf(float(hp) / float(maxi(1, hp_max)), 0.0, 1.0)
	var fill := Color("#5FD16A") if team == int(GameEnums.Team.PLAYER) else Color("#D15F5F")
	draw_rect(Rect2(top_left, Vector2(w * ratio, h)), fill)
	# 格挡叠在血条上方
	if block > 0:
		var bw := minf(w, w * float(block) / float(maxi(1, hp_max)))
		draw_rect(Rect2(top_left + Vector2(0, -h - 1.5), Vector2(bw, h)), Color("#7FA8D9"))
	draw_rect(Rect2(top_left, Vector2(w, h)), Color(0, 0, 0, 0.55), false, 1.5)
