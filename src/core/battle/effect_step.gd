class_name EffectStep
extends Resource
## 卡牌 / 符文 / 状态共用的效果步骤 —— §15.4
##
## 策划案原文：「这套结构能表达绝大多数卡牌与符文，无需写代码」
##            「新增一张卡 = 新增一个 .tres 文件」

@export var op: GameEnums.EffectOp = GameEnums.EffectOp.DEAL_DAMAGE

## ⚠️ §7.5 强制系数化：禁止硬编码伤害数值。
##   最终值 = flat + stats[stat_ref] × stat_ratio
##   例：《重击》flat=0, stat_ref="ATK", ratio=1.8
##       《防御》flat=2, stat_ref="DEF", ratio=1.0
@export var flat_value: float = 0.0
@export var stat_ratio: float = 0.0
@export var stat_ref: String = "ATK"

## 重复次数。⚠️ 离散量不参与系数化（《连刺》repeat=3 就是 3 次）。
## 注意 repeat 会让 ON_ATTACK 触发多次 —— 这是 R7 的压力来源之一。
@export var repeat: int = 1

## 位移/射程类的格数（离散量，不缩放）
@export var distance: int = 0

## 状态相关
@export var status_id: String = ""
@export var status_stacks: int = 0

@export var target_filter: GameEnums.TargetFilter = GameEnums.TargetFilter.ENEMY

## 条件与子步骤（CONDITIONAL 用）
@export var condition_expr: String = ""
@export var sub_steps: Array[EffectStep] = []

## 表现层 id。灰盒期全部留空（§14 红线：不进美术资产）
@export var vfx_id: String = ""
@export var sfx_id: String = ""


## 计算本步的数值（§7.5 的唯一实现）
func value_for(source: Unit) -> float:
	var s := 0.0
	if source != null:
		match stat_ref.to_upper():
			"ATK": s = float(source.atk)
			"DEF": s = float(source.def)
			"AGI": s = float(source.agi)
			"LUK": s = float(source.luk)
			"CRIT": s = float(source.crit)
			"HP": s = float(source.hp)
			"HP_MAX": s = float(source.hp_max)
	return flat_value + s * stat_ratio


## 便捷构造器（用于代码内建数据，避免手写 .tres）
static func make(
	p_op: GameEnums.EffectOp,
	p_flat: float = 0.0,
	p_ref: String = "ATK",
	p_ratio: float = 0.0,
	p_repeat: int = 1
) -> EffectStep:
	var e := EffectStep.new()
	e.op = p_op
	e.flat_value = p_flat
	e.stat_ref = p_ref
	e.stat_ratio = p_ratio
	e.repeat = p_repeat
	return e
