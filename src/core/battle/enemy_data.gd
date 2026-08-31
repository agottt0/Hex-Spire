class_name EnemyData
extends Resource
## 敌人定义 —— §15.8

@export var id: String = ""
@export var display_name: String = ""
## 灰盒期留 null（§14 红线）
@export var sprite: SpriteFrames = null

@export var size_class: GameEnums.SizeClass = GameEnums.SizeClass.S

@export var base_hp: int = 20
@export var base_atk: int = 6
@export var base_def: int = 2
@export var base_agi: int = 5
@export var base_luk: int = 0
@export var base_crit: int = 0

@export var ai_profile: GameEnums.AIProfile = GameEnums.AIProfile.AGGRESSIVE
## ⚠️ §13.2 点名要求玩家能读出"意图是否可躲"
@export var intent_targeting: GameEnums.IntentTargeting = GameEnums.IntentTargeting.FIXED_TILE

@export var knockback_resist_override: int = -1
@export var is_elite: bool = false
@export var is_boss: bool = false
@export_multiline var codex_text: String = ""


## 按层数缩放（§15.8 stat_scaling_by_floor + §9.4 腐蚀度）
func make_unit(floor_index: int = 1, corruption: int = 0) -> Unit:
	var u := Unit.new()
	u.display_name = display_name
	u.source_id = id
	var scale := 1.0 + 0.12 * float(maxi(0, floor_index - 1)) + 0.08 * float(corruption)
	u.hp_max = maxi(1, int(round(float(base_hp) * scale)))
	u.hp = u.hp_max
	u.atk = maxi(1, int(round(float(base_atk) * scale)))
	u.def = base_def
	u.agi = base_agi
	u.luk = base_luk
	u.crit = base_crit
	u.size_class = size_class
	u.size_data = SizeClassData.make(size_class)
	u.team = GameEnums.Team.ENEMY
	u.ai_profile = ai_profile
	u.intent_targeting = intent_targeting
	u.knockback_resist_override = knockback_resist_override
	u.is_elite = is_elite
	u.is_boss = is_boss
	return u
