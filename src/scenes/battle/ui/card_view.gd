extends Panel
class_name CardView
## 卡牌的灰盒表现 —— 纯色 Panel + 文字，零美术资产
##
## §12 的信息层级（从上到下，重要性递减）：
##   ① 体力消耗（左上角，最大数字）  ← 最高频读取
##   ② 卡名（中）
##   ③ 效果数值（高亮）              ← 第二高频
##   ④ 效果描述（小）
##   ⑤ 插画（灰盒期无）
##
## ⚠️ 描述用【实算值】填充 —— 这同时验证 §7.5：
##    ATK 翻 20 倍后卡面自动从 "18 伤害" 变 "360"

signal card_clicked(view: CardView)

const W := 132
const H := 178

## 按 card_type 上色（灰盒期用底色区分类型，比图标便宜且同样清晰）
const TYPE_COLORS := {
	GameEnums.CardType.ATTACK: Color("#6B2A2A"),
	GameEnums.CardType.GUARD: Color("#2A4A6B"),
	GameEnums.CardType.MOVE: Color("#2A6B45"),
	GameEnums.CardType.SKILL: Color("#5A2A6B"),
	GameEnums.CardType.STANCE: Color("#6B5A2A"),
	GameEnums.CardType.DERIVED: Color("#3A3A45"),
	GameEnums.CardType.CURSE: Color("#1A1A1A"),
}

var card_uid: int = -1
var card_id: String = ""
var playable := true
var selected := false

var _cost_label: Label
var _name_label: Label
var _desc_label: Label
var _style: StyleBoxFlat


func _ready() -> void:
	custom_minimum_size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_style = StyleBoxFlat.new()
	_style.corner_radius_top_left = 6
	_style.corner_radius_top_right = 6
	_style.corner_radius_bottom_left = 6
	_style.corner_radius_bottom_right = 6
	_style.border_width_left = 2
	_style.border_width_right = 2
	_style.border_width_top = 2
	_style.border_width_bottom = 2
	add_theme_stylebox_override("panel", _style)

	_cost_label = Label.new()
	_cost_label.add_theme_font_size_override("font_size", 26)
	_cost_label.position = Vector2(7, 2)
	add_child(_cost_label)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 16)
	_name_label.position = Vector2(7, 36)
	_name_label.size = Vector2(W - 14, 22)
	add_child(_name_label)

	_desc_label = Label.new()
	_desc_label.add_theme_font_size_override("font_size", 12)
	_desc_label.position = Vector2(7, 62)
	_desc_label.size = Vector2(W - 14, H - 70)
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	add_child(_desc_label)

	gui_input.connect(_on_gui_input)


func setup(uid: int, cd: CardData, cost: int, desc: String, can_play: bool) -> void:
	card_uid = uid
	card_id = cd.id
	playable = can_play
	_cost_label.text = str(cost)
	_name_label.text = cd.display_name
	_desc_label.text = desc
	_style.bg_color = TYPE_COLORS.get(cd.card_type, Color("#3A3A45"))
	_refresh_border()


func set_selected(v: bool) -> void:
	selected = v
	_refresh_border()


func _refresh_border() -> void:
	if _style == null:
		return
	var c: Color
	if selected:
		c = Color("#FFC94D")   # 选中 = 金
	elif playable:
		c = Color("#E8E8E8")   # 可打出 = 白边
	else:
		c = Color("#55555A")   # 体力不足 = 灰边
	_style.border_color = c
	modulate.a = 1.0 if playable else 0.55
	var w := 4 if selected else 2
	_style.border_width_left = w
	_style.border_width_right = w
	_style.border_width_top = w
	_style.border_width_bottom = w


func _on_gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		card_clicked.emit(self)
