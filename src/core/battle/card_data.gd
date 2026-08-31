class_name CardData
extends Resource
## 卡牌定义 —— §15.3
##
## §15.4 原文：「新增一张卡 = 新增一个 .tres 文件」

@export var id: String = ""
@export var display_name: String = ""
## 灰盒期留 null（§14 红线：不进美术资产）
@export var art: Texture2D = null

@export var card_type: GameEnums.CardType = GameEnums.CardType.ATTACK
@export var rarity: GameEnums.Rarity = GameEnums.Rarity.COMMON
@export var energy_cost: int = 1

## 标签仅用于检索与加权，【不产生任何加成】（§7.8）
@export var tags: Array[String] = []

@export var target_spec: TargetSpec = null
@export var effects: Array[EffectStep] = []

@export var is_cornerstone: bool = false
@export var is_exhaust: bool = false
@export var counts_toward_capacity: bool = true
@export var max_copies_in_deck: int = 3

@export var upgraded_version: CardData = null

## 描述模板。运行时用【实算值】填充 —— 这同时验证了 §7.5：
## 卡面显示"造成 18 伤害"，ATK 翻 20 倍后自动变"360"。
## 占位符：{dmg} {block} {dist} {stacks} {repeat}
@export_multiline var description_template: String = ""


## 用实算值渲染描述（§13.2 的可读性要求 + §7.5 的验证手段）
func render_description(source: Unit) -> String:
	var s := description_template
	if s == "":
		s = _auto_description(source)
		return s
	for e in effects:
		var v := int(e.value_for(source))
		match e.op:
			GameEnums.EffectOp.DEAL_DAMAGE:
				s = s.replace("{dmg}", str(v))
			GameEnums.EffectOp.GAIN_BLOCK:
				s = s.replace("{block}", str(v))
			_:
				pass
		s = s.replace("{stacks}", str(e.status_stacks))
		s = s.replace("{repeat}", str(e.repeat))
		s = s.replace("{dist}", str(e.distance))
	return s


## 没写模板时自动生成一句（灰盒期够用）
func _auto_description(source: Unit) -> String:
	var parts: Array[String] = []
	for e in effects:
		var v := int(e.value_for(source))
		match e.op:
			GameEnums.EffectOp.DEAL_DAMAGE:
				if e.repeat > 1:
					parts.append("造成 %d 伤害 ×%d" % [v, e.repeat])
				else:
					parts.append("造成 %d 伤害" % v)
			GameEnums.EffectOp.GAIN_BLOCK:
				parts.append("获得 %d 格挡" % v)
			GameEnums.EffectOp.HEAL:
				parts.append("恢复 %d 生命" % v)
			GameEnums.EffectOp.MOVE_SELF:
				parts.append("移动 %d 格" % e.distance)
			GameEnums.EffectOp.DASH:
				parts.append("冲刺 %d 格" % e.distance)
			GameEnums.EffectOp.KNOCKBACK:
				parts.append("击退 %d 格" % e.distance)
			GameEnums.EffectOp.PULL:
				parts.append("拉近 %d 格" % e.distance)
			GameEnums.EffectOp.APPLY_STATUS:
				parts.append("施加 %s %d 层" % [e.status_id, e.status_stacks])
			GameEnums.EffectOp.DRAW_CARD:
				parts.append("抽 %d 张" % e.repeat)
			GameEnums.EffectOp.GAIN_ENERGY:
				parts.append("获得 %d 体力" % v)
			GameEnums.EffectOp.ROTATE:
				parts.append("转向")
			GameEnums.EffectOp.TRAMPLE:
				parts.append("碾压")
			_:
				parts.append(str(GameEnums.EffectOp.keys()[e.op]))
	return "，".join(parts)


## 首个伤害步（供伤害预览用）
func primary_damage_step() -> EffectStep:
	for e in effects:
		if e.op == GameEnums.EffectOp.DEAL_DAMAGE:
			return e
	return null


func is_attack() -> bool:
	return card_type == GameEnums.CardType.ATTACK


func needs_target() -> bool:
	if target_spec == null:
		return false
	return target_spec.shape != GameEnums.TargetShape.SELF
