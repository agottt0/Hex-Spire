class_name HeroData
extends Resource
## 英雄定义 —— §15.1

@export var id: String = ""
@export var display_name: String = ""
## 灰盒期留 null（§14 红线）
@export var portrait: Texture2D = null
@export var battle_sprite: SpriteFrames = null

@export var size_class: GameEnums.SizeClass = GameEnums.SizeClass.S

## 六属性基线（§4.3）
@export var base_hp: int = 80
@export var base_atk: int = 10
@export var base_def: int = 8
@export var base_agi: int = 6
@export var base_luk: int = 5
@export var base_crit: int = 10

@export var energy_max: int = 5
@export var cards_drawn_per_turn: int = 5

## 三张基石卡（§7.2）
@export var cornerstone_card_ids: Array[String] = []
## 卡池标签（§7.8：仅用于检索与加权）
@export var card_pool_tags: Array[String] = []

## 被动天赋改写的规则（§15.1 里是 RuneData，此处简化为直接的规则映射）
## 形如 { GameRule: value }
@export var passive_rules: Dictionary = {}
@export var passive_text: String = ""


func apply_to_unit(u: Unit) -> void:
	u.display_name = display_name
	u.source_id = id
	u.hp_max = base_hp
	u.hp = base_hp
	u.atk = base_atk
	u.def = base_def
	u.agi = base_agi
	u.luk = base_luk
	u.crit = base_crit
	u.size_class = size_class
	u.size_data = SizeClassData.make(size_class)
	u.team = GameEnums.Team.PLAYER
