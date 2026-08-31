class_name RuleBook
## 每条 GameRule 的【唯一消费点】—— §15.6 的硬要求
##
## 策划案原文：「每个 GameRule 只有一个消费点」。
## 这个要求靠自觉是守不住的（P4 加符文时会散落十几处偷读），
## 所以用 注册表 + 源码扫描测试 机械强制：
##   · CONSUMERS 把每条规则映射到唯一函数名
##   · tools/check_discipline.gd 扫描 src/，除 enums.gd / rule_book.gd /
##     rune_loadout.gd 外出现 `GameRule.XXX` 即报错
##
## 用法：所有需要读取"当前有效规则值"的地方都调这里的函数，
##       禁止直接读 state.rule_agg，更禁止读 rune_loadout。
##
## state.rule_agg 由 RuneLoadout.aggregate_rule() 在 BattleStart 与任何
## loadout 变更时【一次性预聚合】（按 apply_order 升序、同序按槽位升序）。

## 每条 GameRule → 唯一消费函数名。测试校验一对一且全覆盖。
const CONSUMERS := {
	GameEnums.GameRule.ENERGY_MAX: "energy_max",
	GameEnums.GameRule.CARDS_DRAWN_PER_TURN: "cards_drawn_per_turn",
	GameEnums.GameRule.HAND_LIMIT: "hand_limit",
	GameEnums.GameRule.DECK_CAPACITY: "deck_capacity",
	GameEnums.GameRule.CARD_COST_DELTA: "card_cost",
	GameEnums.GameRule.FIRST_CARD_FREE: "is_first_card_free",
	GameEnums.GameRule.NO_DRAW_FIXED_HAND: "is_fixed_hand",
	GameEnums.GameRule.SIZE_CLASS_OVERRIDE: "size_class_of",
	GameEnums.GameRule.KNOCKBACK_IMMUNE: "knockback_resist_of",
	GameEnums.GameRule.BLOCK_PERSISTS: "block_persists",
	GameEnums.GameRule.DAMAGE_MULTIPLIER: "damage_multiplier",
	GameEnums.GameRule.BLOCK_MULTIPLIER: "block_multiplier",
	GameEnums.GameRule.CRIT_DAMAGE_MULTIPLIER: "crit_damage_multiplier",
	GameEnums.GameRule.NO_BLOCK_ALLOWED: "can_gain_block",
	GameEnums.GameRule.MOVE_COST_DELTA: "move_cost_delta",
	GameEnums.GameRule.EXHAUST_ALL_ATTACKS: "attacks_exhaust",
}


static func _agg(state, rule: int, fallback: Variant) -> Variant:
	if state == null:
		return fallback
	var d: Dictionary = state.rule_agg
	if d.has(rule):
		return d[rule]
	return fallback


# ------------------------------------------------------------------ 体力与抽牌

static func energy_max(state) -> int:
	return int(_agg(state, GameEnums.GameRule.ENERGY_MAX, state.hero_energy_max_base))


static func cards_drawn_per_turn(state) -> int:
	return int(_agg(state, GameEnums.GameRule.CARDS_DRAWN_PER_TURN, state.hero_draw_base))


static func hand_limit(state) -> int:
	return int(_agg(state, GameEnums.GameRule.HAND_LIMIT, K.HAND_LIMIT))


static func deck_capacity(state) -> int:
	return int(_agg(state, GameEnums.GameRule.DECK_CAPACITY, state.deck_capacity_base))


static func is_fixed_hand(state) -> bool:
	return bool(_agg(state, GameEnums.GameRule.NO_DRAW_FIXED_HAND, false))


static func is_first_card_free(state) -> bool:
	return bool(_agg(state, GameEnums.GameRule.FIRST_CARD_FREE, false))


# ------------------------------------------------------------------ 卡牌费用

## 实际费用 = 卡面 cost + CARD_COST_DELTA，最低 0。
## 若本回合尚未打牌且 FIRST_CARD_FREE 生效 → 0。
static func card_cost(state, base_cost: int, cards_played_this_round: int = -1) -> int:
	var played := cards_played_this_round
	if played < 0 and state != null:
		played = state.cards_played_this_round
	if is_first_card_free(state) and played == 0:
		return 0
	var delta := int(_agg(state, GameEnums.GameRule.CARD_COST_DELTA, 0))
	return maxi(0, base_cost + delta)


static func attacks_exhaust(state) -> bool:
	return bool(_agg(state, GameEnums.GameRule.EXHAUST_ALL_ATTACKS, false))


# ------------------------------------------------------------------ 体型与位移

## 体型可被符文改写（《巨化》：SIZE_CLASS_OVERRIDE = L）
static func size_class_of(state, unit: Unit) -> GameEnums.SizeClass:
	if unit == null:
		return GameEnums.SizeClass.S
	# 只对玩家单位生效（符文装在玩家身上）
	if unit.team == GameEnums.Team.PLAYER:
		var ov = _agg(state, GameEnums.GameRule.SIZE_CLASS_OVERRIDE, null)
		if ov != null:
			return int(ov) as GameEnums.SizeClass
	return unit.size_class


static func knockback_resist_of(state, unit: Unit) -> int:
	if unit == null:
		return 0
	if unit.team == GameEnums.Team.PLAYER:
		if bool(_agg(state, GameEnums.GameRule.KNOCKBACK_IMMUNE, false)):
			return 999
	return unit.knockback_resist()


static func move_cost_delta(state) -> int:
	return int(_agg(state, GameEnums.GameRule.MOVE_COST_DELTA, 0))


# ------------------------------------------------------------------ 格挡

## 骑士被动：格挡不在回合结束清空
static func block_persists(state) -> bool:
	return bool(_agg(state, GameEnums.GameRule.BLOCK_PERSISTS, false))


## 《巨化》的代价之一：无法获得格挡
static func can_gain_block(state) -> bool:
	return not bool(_agg(state, GameEnums.GameRule.NO_BLOCK_ALLOWED, false))


static func block_multiplier(state) -> float:
	return float(_agg(state, GameEnums.GameRule.BLOCK_MULTIPLIER, 1.0))


# ------------------------------------------------------------------ 伤害乘区

static func damage_multiplier(state) -> float:
	return float(_agg(state, GameEnums.GameRule.DAMAGE_MULTIPLIER, 1.0))


static func crit_damage_multiplier(state) -> float:
	return float(_agg(state, GameEnums.GameRule.CRIT_DAMAGE_MULTIPLIER, 1.0))
