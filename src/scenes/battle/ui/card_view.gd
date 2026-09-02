extends Panel
class_name CardView
## 卡牌表现 —— 卡框图 + 插画水印 + 文字
##
## §12 的信息层级（从上到下，重要性递减）：
##   ① 体力消耗（左上角，最大数字）  ← 最高频读取
##   ② 卡名（中）
##   ③ 效果数值（高亮）              ← 第二高频
##   ④ 效果描述（小）
##   ⑤ 插画
##
## ⚠️ 描述用【实算值】填充 —— 这同时验证 §7.5：
##    ATK 翻 20 倍后卡面自动从 "18 伤害" 变 "360"
##
## ── 为什么插画是【铺满的半透明水印】而不是独立插画区 ──────────────
## 卡面只有 132×178。给插画切出一块矩形，描述区就会从 108px 压到 ~42px，
## 实算值描述会被截断 —— 那等于用最低优先级的 ⑤ 挤掉了 ④，
## 还顺手废掉了 §7.5 的验证窗口。
## 铺满 + 压低 alpha + 文字描边，既拿到视觉识别，又不动任何文字空间。

signal card_clicked(view: CardView)

const W := 132
const H := 178

## 卡框与插画资产
const CARD_ART_ROOT := "res://Art/Card/"
const FRAME_TEX := CARD_ART_ROOT + "Card_Black.png"

## 插画：先按 card_id 精确匹配（三张基石卡有专属图），
## 否则按 card_type 回退，让后续新卡也有合适底图。
const ART_BY_ID := {
	"atk_basic": "Attack.png",
	"def_basic": "Defend.png",
	"move_basic": "Move.png",
}
const ART_BY_TYPE := {
	GameEnums.CardType.ATTACK: "Attack.png",
	GameEnums.CardType.GUARD: "Defend.png",
	GameEnums.CardType.MOVE: "Move.png",
}

## 插画水印透明度 —— 再高就开始吃文字可读性
const ART_ALPHA := 0.38
## 卡框内缩，露出 StyleBox 的类型底色与状态边框
const INSET := 3.0

## 按 card_type 上色（底色区分类型，比图标便宜且同样清晰）
const TYPE_COLORS := {
	GameEnums.CardType.ATTACK: Color("#6B2A2A"),
	GameEnums.CardType.GUARD: Color("#2A4A6B"),
	GameEnums.CardType.MOVE: Color("#2A6B45"),
	GameEnums.CardType.SKILL: Color("#5A2A6B"),
	GameEnums.CardType.STANCE: Color("#6B5A2A"),
	GameEnums.CardType.DERIVED: Color("#3A3A45"),
	GameEnums.CardType.CURSE: Color("#1A1A1A"),
}

# _sync_hand 每次刷新都重建全部 CardView，纹理必须缓存
static var _tex_cache: Dictionary = {}

var card_uid: int = -1
var card_id: String = ""
var playable := true
var selected := false

var _frame_rect: TextureRect
var _art_rect: TextureRect
var _cost_label: Label
var _name_label: Label
var _desc_label: Label
var _style: StyleBoxFlat


static func _tex(file: String) -> Texture2D:
	if _tex_cache.has(file):
		return _tex_cache[file]
	var p := file
	if not p.begins_with("res://"):
		p = CARD_ART_ROOT + p
	var t: Texture2D = null
	if ResourceLoader.exists(p):
		t = load(p) as Texture2D
	_tex_cache[file] = t
	return t


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

	# ── 图层顺序：StyleBox（类型色 + 状态边框）→ 卡框图 → 插画水印 → 文字
	_frame_rect = _mk_fill_rect(_tex(FRAME_TEX), 0.92)
	_art_rect = _mk_fill_rect(null, ART_ALPHA)

	_cost_label = _mk_label(26, Vector2(7, 2))
	_name_label = _mk_label(16, Vector2(7, 36))
	_name_label.size = Vector2(W - 14, 22)
	_desc_label = _mk_label(12, Vector2(7, 62))
	_desc_label.size = Vector2(W - 14, H - 70)
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP

	gui_input.connect(_on_gui_input)


## 内缩铺满的 TextureRect（露出边框）
func _mk_fill_rect(tex: Texture2D, alpha: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r.modulate = Color(1, 1, 1, alpha)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.clip_contents = true
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.offset_left = INSET
	r.offset_top = INSET
	r.offset_right = -INSET
	r.offset_bottom = -INSET
	add_child(r)
	return r


## 带描边的 Label —— 描边让文字在插画水印上仍然清晰（§12 信息优先）
func _mk_label(font_size: int, pos: Vector2) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func setup(uid: int, cd: CardData, cost: int, desc: String, can_play: bool) -> void:
	card_uid = uid
	card_id = cd.id
	playable = can_play
	_cost_label.text = str(cost)
	_name_label.text = cd.display_name
	_desc_label.text = desc
	_style.bg_color = TYPE_COLORS.get(cd.card_type, Color("#3A3A45"))
	_art_rect.texture = _art_for(cd)
	_refresh_border()


func _art_for(cd: CardData) -> Texture2D:
	if ART_BY_ID.has(cd.id):
		return _tex(ART_BY_ID[cd.id])
	if ART_BY_TYPE.has(cd.card_type):
		return _tex(ART_BY_TYPE[cd.card_type])
	return null


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
