extends Node2D
## 战斗场景 —— 表现层入口
##
## ⚠️ 纪律 3 的兑现处：
##   本文件【只订阅事件、只发送玩家输入】，绝不驱动逻辑。
##   逻辑（BattleFlow）瞬时算完，这里每帧 drain state.event_log 回放。
##   "一键跳过动画" = 把 K.EVENT_PLAYBACK_INTERVAL 改成 0。

const HL := GreyboxTileSet.Alt

## 章节场景背景。氛围只在【战场之外】发挥 ——
## 美术文档 R7：格线必须始终可见；R1：地面明度对比 ≤20%。
## 所以背景压暗并铺在 TileMapLayer 之下，不参与战场可读性。
const BG_PATH := "res://Art/Scene1/Chapter1_BattleScene.png"
const BG_DIM := Color(0.58, 0.58, 0.66)
## 相对战场外接矩形的覆盖系数
const BG_COVER := 1.25

var state: BattleState
var flow: BattleFlow

var background: Sprite2D
var board: HexBoardView
var units_root: Node2D
var ui_layer: CanvasLayer
var camera: Camera2D

var hand_box: HBoxContainer
var status_label: Label
var hero_portrait: TextureRect
var hero_label: Label
var enemy_info: Label
var preview_label: Label
var log_label: Label
var end_turn_btn: Button
var restart_btn: Button
var hero_option: OptionButton
var layout_option: OptionButton
var enc_option: OptionButton

var _unit_views: Dictionary = {}      ## unit_id -> UnitView
var _card_views: Array[CardView] = []
var _selected_card: CardView = null
var _legal_cells: Array = []
var _log_lines: Array[String] = []


func _ready() -> void:
	_build_scene()
	# 开发期：--hero=/--layout=/--enc= 可覆盖默认开局，便于无人值守核对各体型
	var hero := "knight"
	var layout := "open_hall"
	var enc := "enc_01"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hero="):
			hero = a.split("=")[1]
		elif a.begins_with("--layout="):
			layout = a.split("=")[1]
		elif a.begins_with("--enc="):
			enc = a.split("=")[1]
	_start_battle(hero, layout, enc)
	_select_option(hero_option, hero)
	_select_option(layout_option, layout)
	_select_option(enc_option, enc)
	# 开发期：--shot 参数启动后自动截图并退出（无人值守验证画面）
	#   可选 --shot-name=xxx 指定文件名，便于多分辨率对比
	for a in OS.get_cmdline_user_args():
		if a == "--shot" or a.begins_with("--shot="):
			_auto_screenshot()
			break


func _auto_screenshot() -> void:
	for _i in range(20):
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var suffix := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot-name="):
			suffix = "_" + a.split("=")[1]
	var out := "user://battle_shot%s.png" % suffix
	img.save_png(out)
	print("[shot] %s  %dx%d" % [ProjectSettings.globalize_path(out),
		img.get_width(), img.get_height()])
	get_tree().quit(0)


# ══════════════════════════════════════════════════════ 场景搭建
#
# ⚠️ 分辨率适配（这里曾写死 1920×1080 绝对坐标，小屏幕下 UI 跑到画面外）：
#   · 工程用 canvas_items + aspect="keep" → 整个画布等比缩放，两侧留黑边
#   · UI 全部用【锚点 + offset】而非绝对 position，
#     这样即使基准分辨率改变、或用 aspect="expand" 也不会跑飞
#   · 战场相机按【实际可用区】算缩放，不用硬编码的 300/280/210
#
# 面板宽度用基准分辨率的比例定义，改基准不用改代码。

const UI_LEFT_W := 300.0     ## 左侧面板宽
const UI_RIGHT_W := 200.0    ## 右侧按钮区宽
const UI_TOP_H := 40.0       ## 顶部状态条高
const UI_HAND_H := 200.0     ## 底部手牌区高


func _build_scene() -> void:
	# 章节背景（铺在战场之下，不影响格线与高亮层的可读性）
	if ResourceLoader.exists(BG_PATH):
		background = Sprite2D.new()
		background.name = "Background"
		background.texture = load(BG_PATH)
		background.modulate = BG_DIM
		background.z_index = -10
		add_child(background)

	board = HexBoardView.new()
	board.name = "Board"
	add_child(board)

	units_root = Node2D.new()
	units_root.name = "Units"
	units_root.z_index = 10
	add_child(units_root)

	camera = Camera2D.new()
	add_child(camera)

	ui_layer = CanvasLayer.new()
	add_child(ui_layer)

	# ---- 顶部状态条（贴顶，横向拉满）
	status_label = _mk_label(ui_layer, 20)
	_anchor(status_label, 0.0, 0.0, 1.0, 0.0, Vector4(16, 8, -16, 34))

	# ---- 左侧：英雄面板 → 敌人信息 → 伤害预览 → 事件日志
	#      纵向串成一列，用 VBoxContainer 自动排布，避免手算 y 坐标
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 14)
	ui_layer.add_child(left)
	_anchor(left, 0.0, 0.0, 0.0, 1.0, Vector4(16, UI_TOP_H, UI_LEFT_W, -UI_HAND_H))

	hero_portrait = TextureRect.new()
	hero_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hero_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hero_portrait.custom_minimum_size = Vector2(0, 150)
	left.add_child(hero_portrait)

	hero_label = _mk_label(left, 15)
	enemy_info = _mk_label(left, 14)
	preview_label = _mk_label(left, 17)
	preview_label.add_theme_color_override("font_color", Color("#FFC94D"))
	log_label = _mk_label(left, 12)
	log_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# ---- 底部手牌区（贴底，水平居中）
	hand_box = HBoxContainer.new()
	hand_box.add_theme_constant_override("separation", 8)
	hand_box.alignment = BoxContainer.ALIGNMENT_CENTER
	ui_layer.add_child(hand_box)
	_anchor(hand_box, 0.0, 1.0, 1.0, 1.0,
		Vector4(UI_LEFT_W, -UI_HAND_H + 6, -UI_RIGHT_W, -8))

	# ---- 右上：配置下拉（贴右上角）
	var right_top := VBoxContainer.new()
	right_top.add_theme_constant_override("separation", 6)
	ui_layer.add_child(right_top)
	_anchor(right_top, 1.0, 0.0, 1.0, 0.0, Vector4(-UI_RIGHT_W + 8, 12, -8, 200))

	hero_option = _mk_option(right_top, ["knight", "giant"])
	layout_option = _mk_option(right_top,
		["open_hall", "narrow_pass", "bottleneck", "spike_cell"])
	enc_option = _mk_option(right_top, ["enc_01", "enc_02", "enc_03", "enc_04"])

	var hint := _mk_label(right_top, 12)
	hint.text = "F1 坐标\n右键取消\n改配置后点重开"

	# ---- 右下：按钮（贴右下角）
	var right_bottom := VBoxContainer.new()
	right_bottom.add_theme_constant_override("separation", 8)
	ui_layer.add_child(right_bottom)
	_anchor(right_bottom, 1.0, 1.0, 1.0, 1.0, Vector4(-UI_RIGHT_W + 8, -110, -8, -12))

	end_turn_btn = Button.new()
	end_turn_btn.text = "结束回合 (空格)"
	end_turn_btn.custom_minimum_size = Vector2(0, 46)
	end_turn_btn.pressed.connect(_on_end_turn)
	right_bottom.add_child(end_turn_btn)

	restart_btn = Button.new()
	restart_btn.text = "重开"
	restart_btn.custom_minimum_size = Vector2(0, 38)
	restart_btn.pressed.connect(_on_restart)
	right_bottom.add_child(restart_btn)

	# 窗口尺寸变化时重新居中相机
	get_viewport().size_changed.connect(_center_camera)


## 设置锚点 + offset。offsets = (left, top, right, bottom)
## 负值表示"距对边的距离"，这是 Godot 锚点布局的标准用法。
func _anchor(c: Control, al: float, at: float, ar: float, ab: float, offsets: Vector4) -> void:
	c.anchor_left = al
	c.anchor_top = at
	c.anchor_right = ar
	c.anchor_bottom = ab
	c.offset_left = offsets.x
	c.offset_top = offsets.y
	c.offset_right = offsets.z
	c.offset_bottom = offsets.w


func _mk_label(parent: Node, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


func _mk_option(parent: Node, items: Array) -> OptionButton:
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(0, 30)
	for it in items:
		o.add_item(it)
	parent.add_child(o)
	return o


## 让下拉框与命令行覆盖的开局保持一致，否则点「重开」会跳回默认配置
func _select_option(o: OptionButton, value: String) -> void:
	if o == null:
		return
	for i in range(o.item_count):
		if o.get_item_text(i) == value:
			o.selected = i
			return


# ══════════════════════════════════════════════════════ 开局

func _start_battle(hero_id: String, layout_id: String, enc_id: String) -> void:
	CardInstance.reset_uid_counter()
	var seed_value := int(Time.get_unix_time_from_system()) & 0x7FFFFFFF
	var setup := BattleSetup.create(hero_id, layout_id, enc_id, seed_value)
	state = setup["state"]
	flow = setup["flow"]

	_log_lines.clear()
	for k in _unit_views:
		(_unit_views[k] as Node).queue_free()
	_unit_views.clear()

	board.render_grid(state.grid)
	_center_camera()
	# 无立绘资产的英雄不占版面
	var portrait := UnitSprites.portrait_for(hero_id)
	hero_portrait.texture = portrait
	hero_portrait.visible = portrait != null

	flow.battle_start(setup["deck"])
	_sync_all()


## 战场外接矩形顶部要为【单位立绘 + 头顶标签】留出的额外高度（单位 = 格高）。
##
## ⚠️ board_rect() 只按格子几何算，上下各留半格。但角色 sprite 从脚底往上
##   可达 1.6 格高（S）+ 头顶两行标签，第 7 行（最上排）的单位会被视口
##   裁掉头部 —— 实测敌人只剩下半身。
##
## ⚠️ 这个值【不能取大】：它会参与 zoom 计算，留白越多整个战场越小。
##   取 2.1 时 zoom 从 1.03 掉到 0.75，单位明显偏小且底部露出空档（实测）。
##   按 S 体型精算：sprite 顶 1.6 格 + 两行标签 ≈ 250px，board_rect 已含
##   0.5 格 = 74px，故实需 (250-74)/148 ≈ 1.19 格。取 1.35 留一点余量。
##   M/L 体型更高，但它们生成在下半区，不会贴到视口上边缘。
const BOARD_TOP_HEADROOM := 1.35


func _center_camera() -> void:
	if board == null or camera == null:
		return
	var r := board.board_rect()
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return

	# 取景用【含立绘留白】的矩形，背景也按它铺，避免缩放后露出画布底色
	var framed := r.grow_individual(0.0, float(K.TILE_H) * BOARD_TOP_HEADROOM, 0.0, 0.0)
	_fit_background(framed)

	# ⚠️ 用【实际视口尺寸】而非硬编码 1920×1080。
	#   canvas_items + aspect="keep" 下 get_visible_rect() 给出的是
	#   基准分辨率的逻辑尺寸（缩放由引擎负责），所以这里的算法
	#   在任何窗口大小下都成立。
	var vp := get_viewport_rect().size

	# 战场可用区 = 视口减去四周 UI
	var avail := Vector2(
		maxf(vp.x - UI_LEFT_W - UI_RIGHT_W, 200.0),
		maxf(vp.y - UI_TOP_H - UI_HAND_H, 200.0))

	var zoom_f := minf(avail.x / framed.size.x, avail.y / framed.size.y)
	camera.zoom = Vector2.ONE * clampf(zoom_f, 0.25, 1.5)

	# 把战场中心对准可用区中心（而非视口中心）
	var avail_center := Vector2(UI_LEFT_W + avail.x * 0.5, UI_TOP_H + avail.y * 0.5)
	var vp_center := vp * 0.5
	camera.position = framed.get_center() + (vp_center - avail_center) / camera.zoom.x


## 背景铺满战场外接矩形的 BG_COVER 倍。
## ⚠️ 缩放上限卡在 1.0：放大会让 2048×1152 的底图糊掉，
##   而糊掉的底图会削弱美术文档 V1「日常的可信度」。宽度不足处露出画布底色即可。
func _fit_background(r: Rect2) -> void:
	if background == null or background.texture == null:
		return
	var tex := background.texture.get_size()
	if tex.x <= 0.0 or tex.y <= 0.0:
		return
	var need := r.size * BG_COVER
	var s := maxf(need.x / tex.x, need.y / tex.y)
	background.scale = Vector2.ONE * minf(s, 1.0)
	background.position = r.get_center()


## 让某个单位播一次攻击动画。单位无美术资产时静默跳过。
func _play_attack_anim(uid: int) -> void:
	var v: UnitView = _unit_views.get(uid)
	if v != null:
		v.play_attack()


# ══════════════════════════════════════════════════════ 输入

func _unhandled_input(ev: InputEvent) -> void:
	if ev.is_action_pressed("toggle_coord_debug"):
		board.toggle_coords()
	elif ev.is_action_pressed("end_turn"):
		_on_end_turn()
	elif ev.is_action_pressed("cancel_action"):
		_clear_selection()
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		_try_play_at_mouse()
	elif ev is InputEventMouseMotion:
		_update_preview()


func _on_card_clicked(v: CardView) -> void:
	if state.is_over or state.phase != GameEnums.BattlePhase.PLAYER_PHASE:
		return
	if not v.playable:
		_flash("体力不足")
		return
	if _selected_card == v:
		_clear_selection()
		return
	_select_card(v)


func _select_card(v: CardView) -> void:
	for c in _card_views:
		c.set_selected(false)
	_selected_card = v
	v.set_selected(true)

	var card := state.piles.find_in_hand(v.card_uid)
	var player := state.player()
	if card == null or player == null:
		return
	var cd: CardData = card.data

	board.clear_highlight()
	_legal_cells.clear()

	if not cd.needs_target():
		# 无目标卡：直接可打，高亮自身
		board.paint_highlight(player.cells(), HL.HL_LEGAL)
		return

	_legal_cells = TargetResolver.legal_cells(state, player, cd.target_spec)
	var alt := HL.HL_MOVE_OK if cd.card_type == GameEnums.CardType.MOVE else HL.HL_LEGAL
	board.paint_highlight(_legal_cells, alt)


func _clear_selection() -> void:
	_selected_card = null
	_legal_cells.clear()
	for c in _card_views:
		c.set_selected(false)
	board.clear_highlight()
	_paint_intents()
	preview_label.text = ""


func _try_play_at_mouse() -> void:
	if _selected_card == null or state.is_over:
		return
	var card := state.piles.find_in_hand(_selected_card.card_uid)
	if card == null:
		_clear_selection()
		return
	var cd: CardData = card.data

	var target := Vector3i.ZERO
	if cd.needs_target():
		var o := board.cell_at_mouse()
		if o.x < 0:
			return
		target = HexCoord.offset_to_cube(o.x, o.y)
		if not _legal_cells.has(target):
			_flash("目标非法")
			return

	# 攻击动画是【事后反馈】：逻辑瞬时结算完，这里才播（架构文档 §1）
	var is_attack := cd.card_type == GameEnums.CardType.ATTACK
	var actor := state.player_unit_id

	if flow.play_card(card, target):
		_clear_selection()
		_sync_all()
		if is_attack:
			_play_attack_anim(actor)


func _on_end_turn() -> void:
	if state.is_over or state.phase != GameEnums.BattlePhase.PLAYER_PHASE:
		return
	_clear_selection()

	# 先记下【打算攻击】的敌人 —— 意图是承诺（架构文档 §4.6），
	# 结算后 intent 会被刷成下一回合的，所以必须在 end_turn 之前采集。
	var attackers: Array[int] = []
	for u in state.alive_enemies():
		var kind: int = u.intent.get("kind", 0)
		if kind == int(GameEnums.IntentKind.ATTACK) \
				or kind == int(GameEnums.IntentKind.MULTI_ATTACK):
			attackers.append(u.id)

	flow.end_turn()
	_sync_all()
	for uid in attackers:
		_play_attack_anim(uid)


func _on_restart() -> void:
	_start_battle(
		hero_option.get_item_text(hero_option.selected),
		layout_option.get_item_text(layout_option.selected),
		enc_option.get_item_text(enc_option.selected))


# ══════════════════════════════════════════════════════ 同步（表现层只读）

func _sync_all() -> void:
	_drain_events()
	_sync_units()
	_sync_hand()
	_sync_status()
	_paint_intents()


func _drain_events() -> void:
	for e in state.drain_events():
		var line := _format_event(e)
		if line != "":
			_log_lines.append(line)
	while _log_lines.size() > 16:
		_log_lines.pop_front()
	log_label.text = "\n".join(_log_lines)


func _format_event(e: Dictionary) -> String:
	var t: String = e.get("t", "")
	var d: Dictionary = e.get("d", {})
	match t:
		"round_started":
			return "── 回合 %d ──" % d.get("round", 0)
		"damage_dealt":
			if d.get("dodged", false):
				return "  闪避！"
			var crit := "  暴击!" if d.get("crit", false) else ""
			return "  伤害 %d（格挡吸收 %d）%s" % [
				d.get("amount", 0), d.get("to_block", 0), crit]
		"block_gained":
			if d.get("blocked_by_rule", false):
				return "  无法获得格挡（规则改写）"
			return "  获得格挡 %d（共 %d）" % [d.get("amount", 0), d.get("total", 0)]
		"unit_died":
			return "  ☠ %s 被击败" % d.get("name", "?")
		"deck_reshuffled":
			return "  ♻ 弃牌堆洗回（第 %d 次）" % d.get("times", 0)
		"card_played":
			return "  打出 %s" % d.get("id", "")
		"intent_missed":
			return "  敌人打空了！"
		"rotate_blocked":
			return "  转向失败：空间不足"
		"move_aborted":
			return "  移动中止：%s" % d.get("reason", "")
		"hazard_damage":
			return "  地形伤害 %d（%d 格）" % [d.get("amount", 0), d.get("cells", 0)]
		"knockback_resisted":
			return "  抵抗了击退"
		"battle_ended":
			return "══ %s ══" % ("胜利！" if d.get("won", false) else "失败")
		_:
			return ""


func _sync_units() -> void:
	var seen := {}
	for u in state.units:
		if not u.is_alive:
			continue
		seen[u.id] = true
		var v: UnitView = _unit_views.get(u.id)
		if v == null:
			v = UnitView.new()
			units_root.add_child(v)
			_unit_views[u.id] = v
		var d := u.to_dict()
		var cells: Array = []
		for c in u.cells():
			var o := HexCoord.cube_to_offset(c)
			cells.append([o.x, o.y])
		d["cells"] = cells
		v.intent_text = _intent_brief(u)
		v.sync_from(d, board)
	# 移除已死单位
	for id in _unit_views.keys():
		if not seen.has(id):
			(_unit_views[id] as Node).queue_free()
			_unit_views.erase(id)


func _intent_brief(u: Unit) -> String:
	if u.team != GameEnums.Team.ENEMY or u.intent.is_empty():
		return ""
	var kind: int = u.intent.get("kind", 0)
	match kind:
		int(GameEnums.IntentKind.ATTACK), int(GameEnums.IntentKind.MULTI_ATTACK):
			var tag := "可躲" if u.intent.get("dodgeable", false) else "追踪"
			return "🗡%d [%s]" % [u.intent.get("preview_min", 0), tag]
		int(GameEnums.IntentKind.MOVE):
			return "→ 移动"
		int(GameEnums.IntentKind.SLEEP):
			return "… 待机"
		_:
			return "?"


## 敌人意图的地面高亮（§8.7：预定打击格）
func _paint_intents() -> void:
	if _selected_card != null:
		return
	board.clear_highlight()
	for u in state.alive_enemies():
		var cells: Array = u.intent.get("cells", [])
		var out: Array = []
		for cell in cells:
			out.append(HexCoord.offset_to_cube(cell[0], cell[1]))
		if not out.is_empty():
			board.paint_highlight(out, HL.HL_INTENT)


func _sync_hand() -> void:
	for v in _card_views:
		v.queue_free()
	_card_views.clear()
	var player := state.player()
	if player == null:
		return
	# 手牌按 uid 排序，避免每次刷新顺序跳动
	var hand: Array = state.piles.hand.duplicate()
	hand.sort_custom(func(a: CardInstance, b: CardInstance) -> bool: return a.uid < b.uid)
	for c in hand:
		var cd: CardData = c.data
		if cd == null:
			continue
		var cost := RuleBook.card_cost(state, c.base_cost())
		var v := CardView.new()
		hand_box.add_child(v)
		# ⚠️ 描述用实算值渲染 —— 同时验证 §7.5 的系数化
		v.setup(c.uid, cd, cost, cd.render_description(player), cost <= state.energy)
		v.card_clicked.connect(_on_card_clicked)
		_card_views.append(v)


func _sync_status() -> void:
	var p := state.player()
	var phase_names := ["开局", "回合开始", "玩家阶段", "回合结束", "敌方阶段",
						"结算", "拾取", "胜利", "失败"]
	var ph: String = phase_names[clampi(int(state.phase), 0, 8)]
	status_label.text = "回合 %d   %s   体力 %d/%d   抽牌堆 %d  弃牌堆 %d" % [
		state.round_number, ph, state.energy, RuleBook.energy_max(state),
		state.piles.draw_pile.size(), state.piles.discard_pile.size()]

	if p != null:
		var sz: String = ["S(1格)", "M(3格)", "L(6格)"][clampi(int(p.size_class), 0, 2)]
		hero_label.text = "%s  %s\nHP %d/%d   格挡 %d\nATK %d  DEF %d  AGI %d\nLUK %d  CRIT %d%%" % [
			p.display_name, sz, p.hp, p.hp_max, p.block,
			p.atk, p.def, p.agi, p.luk, p.crit]

	var lines: Array[String] = ["敌人："]
	for u in state.alive_enemies():
		var o := HexCoord.cube_to_offset(u.anchor)
		lines.append("  %s (%d,%d) HP %d/%d  %s" % [
			u.display_name, o.x, o.y, u.hp, u.hp_max, _intent_brief(u)])
	if state.is_over:
		lines.append("")
		lines.append("【%s】点【重开】再来一局" % ("胜利" if state.player_won else "失败"))
	enemy_info.text = "\n".join(lines)

	end_turn_btn.disabled = state.is_over or state.phase != GameEnums.BattlePhase.PLAYER_PHASE


## 伤害预览（§13.2 硬要求）。⚠️ 走 preview 分支，不消耗 RNG。
func _update_preview() -> void:
	if _selected_card == null:
		preview_label.text = ""
		return
	var card := state.piles.find_in_hand(_selected_card.card_uid)
	if card == null:
		return
	var o := board.cell_at_mouse()
	if o.x < 0:
		preview_label.text = ""
		return
	var target := HexCoord.offset_to_cube(o.x, o.y)
	if not _legal_cells.is_empty() and not _legal_cells.has(target):
		preview_label.text = "（目标非法）"
		return
	var pv := flow.preview_card_damage(card, target)
	if pv.is_empty():
		preview_label.text = ""
		return
	var parts: Array[String] = []
	for uid in pv:
		var u := state.unit_by_id(uid)
		var e: Dictionary = pv[uid]
		var total_min := int(e["min"]) * int(e["repeat"])
		var total_max := int(e["max"]) * int(e["repeat"])
		var rep := (" ×%d" % e["repeat"]) if int(e["repeat"]) > 1 else ""
		parts.append("%s: %d（暴击 %d）%s" % [
			u.display_name if u != null else "?", total_min, total_max, rep])
	preview_label.text = "预计伤害  " + "   ".join(parts)
	# 同时高亮实际波及格
	var cd: CardData = card.data
	var player := state.player()
	if player != null:
		var affected := TargetResolver.affected_cells(state, player, cd.target_spec, target)
		if affected.size() > 1:
			board.paint_highlight(affected, HL.HL_AFFECTED)


func _flash(msg: String) -> void:
	_log_lines.append("  ⚠ " + msg)
	log_label.text = "\n".join(_log_lines)
