class_name Unit
extends RefCounted
## 战场单位 —— 策划案 §8.3 / §14.1 unit.gd
##
## 纯逻辑，零 Node 依赖（纪律 3）。可序列化（纪律 2/5）。
## ⚠️ 纪律 4：不假设我方只有 1 个单位。召唤物、被魅惑的敌人都是 Unit。

var id: int = -1
var display_name: String = ""
var team: GameEnums.Team = GameEnums.Team.ENEMY

## 数据来源（HeroData 或 EnemyData 的 id，用于查图鉴/复现）
var source_id: String = ""

# ---- 位置与朝向
var anchor: Vector3i = Vector3i.ZERO
var facing: int = 0

# ---- 体型（D8）
var size_class: GameEnums.SizeClass = GameEnums.SizeClass.S
var size_data: SizeClassData = null

# ---- 六属性（§4.3）。⚠️ 关键数值用 int（纪律 5）
var hp: int = 1
var hp_max: int = 1
var atk: int = 0
var def: int = 0
var agi: int = 0
var luk: int = 0
var crit: int = 0

# ---- 战斗内临时状态
var block: int = 0
var statuses: Array = []          ## Array[StatusInstance]，P2 引入
var is_alive: bool = true

# ---- 敌人专属
var ai_profile: GameEnums.AIProfile = GameEnums.AIProfile.AGGRESSIVE
var intent_targeting: GameEnums.IntentTargeting = GameEnums.IntentTargeting.FIXED_TILE
var intent: Dictionary = {}       ## 冻结的意图（见 §8.7 / enemy_ai.gd）
var is_elite: bool = false
var is_boss: bool = false

# ---- 被规则改写的值（由 RuleBook 消费，不在此直接读 rule_overrides）
var knockback_resist_override: int = -1


## 当前占据的全部格。⚠️ 唯一来源是 HexFootprint（D8 单一出口）。
func cells() -> Array[Vector3i]:
	return HexFootprint.cells(anchor, footprint(), facing)


func footprint() -> Array[Vector3i]:
	if size_data != null:
		return size_data.footprint
	return [Vector3i.ZERO]


func cell_count() -> int:
	return size_data.cell_count if size_data != null else 1


## 相邻格（大体型显著更多 —— §8.2.2 机制点 3）
func adjacent_cells() -> Array[Vector3i]:
	return HexFootprint.adjacent_cells(anchor, footprint(), facing)


## 到某格的距离，从【最近的己方 footprint 格】起算（§8.2.2 机制点 3）
func distance_to_cell(c: Vector3i) -> int:
	return HexFootprint.distance_from(anchor, footprint(), facing, c)


func distance_to_unit(other: Unit) -> int:
	var best := 9999
	for c in other.cells():
		best = mini(best, distance_to_cell(c))
	return best


## 位移抗性：override 优先，否则取体型默认（§8.2.2 机制点 4）
func knockback_resist() -> int:
	if knockback_resist_override >= 0:
		return knockback_resist_override
	return size_data.default_knockback_resist if size_data != null else 0


func rotate_cost() -> int:
	return size_data.default_rotate_cost if size_data != null else 0


func can_trample_below() -> bool:
	return size_data.can_trample_below if size_data != null else false


func can_crush_rubble() -> bool:
	return size_data.can_crush_rubble if size_data != null else false


## 前方方向向量。⚠️ 必须走 facing_dir（陷阱 H1），不能写 DIRS[facing]
func forward_dir() -> Vector3i:
	return HexCoord.facing_dir(facing)


## 背击判定：攻击者是否位于本单位的后弧
## §8.2.3：背击 → 伤害乘区加成 + 无法被闪避
func is_attacked_from_rear(attacker_cell: Vector3i) -> bool:
	for d in HexCoord.backstab_dirs(facing):
		for own in cells():
			if own + d == attacker_cell:
				return true
	return false


func is_hostile_to(other: Unit) -> bool:
	if team == GameEnums.Team.NEUTRAL or other.team == GameEnums.Team.NEUTRAL:
		return false
	return team != other.team


# ------------------------------------------------------------------ 序列化

func to_dict() -> Dictionary:
	var o := HexCoord.cube_to_offset(anchor)
	return {
		"id": id,
		"name": display_name,
		"team": int(team),
		"source_id": source_id,
		"col": o.x, "row": o.y, "facing": facing,
		"size": int(size_class),
		"hp": hp, "hp_max": hp_max,
		"atk": atk, "def": def, "agi": agi, "luk": luk, "crit": crit,
		"block": block,
		"alive": is_alive,
		"ai": int(ai_profile),
		"intent_targeting": int(intent_targeting),
		"intent": intent.duplicate(true),
		"elite": is_elite, "boss": is_boss,
		"kb_override": knockback_resist_override,
	}


static func from_dict(d: Dictionary) -> Unit:
	var u := Unit.new()
	u.id = d.get("id", -1)
	u.display_name = d.get("name", "")
	u.team = d.get("team", GameEnums.Team.ENEMY)
	u.source_id = d.get("source_id", "")
	u.anchor = HexCoord.offset_to_cube(d.get("col", 1), d.get("row", 1))
	u.facing = d.get("facing", 0)
	u.size_class = d.get("size", GameEnums.SizeClass.S)
	u.size_data = SizeClassData.make(u.size_class)
	u.hp = d.get("hp", 1)
	u.hp_max = d.get("hp_max", 1)
	u.atk = d.get("atk", 0)
	u.def = d.get("def", 0)
	u.agi = d.get("agi", 0)
	u.luk = d.get("luk", 0)
	u.crit = d.get("crit", 0)
	u.block = d.get("block", 0)
	u.is_alive = d.get("alive", true)
	u.ai_profile = d.get("ai", GameEnums.AIProfile.AGGRESSIVE)
	u.intent_targeting = d.get("intent_targeting", GameEnums.IntentTargeting.FIXED_TILE)
	u.intent = (d.get("intent", {}) as Dictionary).duplicate(true)
	u.is_elite = d.get("elite", false)
	u.is_boss = d.get("boss", false)
	u.knockback_resist_override = d.get("kb_override", -1)
	return u


func duplicate_unit() -> Unit:
	return Unit.from_dict(to_dict())
