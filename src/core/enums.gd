class_name GameEnums
## 所有共享枚举的唯一定义处。
##
## 放在一处的理由：@export var rule: GameEnums.GameRule 才能在编辑器里
## 显示为下拉框，策划才能直接编 .tres（§15.4 的"新增一张卡 = 新增一个 .tres"）。

# ------------------------------------------------------------------ 体型（D8）

enum SizeClass { S, M, L }

# ------------------------------------------------------------------ 卡牌

enum CardType { ATTACK, GUARD, MOVE, SKILL, STANCE, DERIVED, CURSE }

enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }

# ------------------------------------------------------------------ 效果（§15.4）

enum EffectOp {
	DEAL_DAMAGE,
	GAIN_BLOCK,
	HEAL,
	MOVE_SELF,
	DASH,
	BLINK,
	ROTATE,
	KNOCKBACK,
	PULL,
	SWAP,
	TRAMPLE,
	APPLY_STATUS,
	REMOVE_STATUS,
	DRAW_CARD,
	DISCARD_CARD,
	EXHAUST_CARD,
	SHUFFLE_DISCARD_INTO_DRAW,
	PUT_CARD_ON_TOP,
	GAIN_ENERGY,
	MODIFY_STAT,
	SUMMON,
	MODIFY_TERRAIN,
	TRIGGER_ANOTHER_CARD,
	CONDITIONAL,
}

enum TargetFilter { ENEMY, ALLY, SELF, ALL_IN_AREA, RANDOM_N, LARGEST, NEAREST }

# ------------------------------------------------------------------ 目标（§15.5）

enum TargetShape { SELF, SINGLE, LINE, CONE, BURST, RING, ADJACENT_ALL, TILE }

# ------------------------------------------------------------------ 符文（D6 / §15.6）

enum RuneCategory { RULE_REWRITE, TRIGGER, CONDITIONAL, MULTIPLIER, CURSE }

## 统一触发时机表（§6.3）。
## ⚠️ 新增时机必须同步在 BattleFlow / EffectExecutor 里埋 emit 点，
##    否则符文描述里写的时机永远不会触发（这是最容易漏的一类 bug）。
enum TriggerTiming {
	ON_BATTLE_START,
	ON_ROUND_START,
	ON_ROUND_END,
	ON_CARD_PLAYED,
	ON_ATTACK,              ## ⭐ 伤害管线 ②′ 的顺序钩子（§6.5 的核心）
	ON_DAMAGE_DEALT,
	ON_DAMAGE_TAKEN,
	ON_KILL,
	ON_BLOCK_GAINED,
	ON_BLOCK_BROKEN,
	ON_MOVE_SELF,
	ON_MOVE_ENEMY,
	ON_STATUS_APPLIED,
	ON_CARD_DRAWN,
	ON_CARD_DISCARDED,
	ON_CARD_EXHAUSTED,
	ON_DECK_RESHUFFLED,
	ON_ENERGY_LEFTOVER,
	ON_CRIT,
	ON_DODGE,
	ON_UNIT_DEATH,
	ON_BATTLE_WIN,
}

## 可被符文/装备改写的规则（§15.6）。
## ⚠️ 每一条【必须且只能】在 rule_book.gd 里有一个消费点。
##    由 tests/test_rule_overrides.gd 源码扫描强制。
enum GameRule {
	ENERGY_MAX,
	CARDS_DRAWN_PER_TURN,
	HAND_LIMIT,
	DECK_CAPACITY,
	CARD_COST_DELTA,
	FIRST_CARD_FREE,
	NO_DRAW_FIXED_HAND,
	SIZE_CLASS_OVERRIDE,
	KNOCKBACK_IMMUNE,
	BLOCK_PERSISTS,
	DAMAGE_MULTIPLIER,
	BLOCK_MULTIPLIER,
	CRIT_DAMAGE_MULTIPLIER,
	NO_BLOCK_ALLOWED,
	MOVE_COST_DELTA,
	EXHAUST_ALL_ATTACKS,
}

# ------------------------------------------------------------------ 装备（§15.7）

enum EquipSlot { WEAPON, ARMOR, TRINKET }

# ------------------------------------------------------------------ 敌人（§15.8）

enum AIProfile { AGGRESSIVE, RANGED_KITER, SUPPORT, SUMMONER, TANK, BLOCKER, BOSS_PHASED }

## 意图是否可躲 —— §13.2 点名要求玩家能读出这个区分
enum IntentTargeting {
	FIXED_TILE,     ## 锁定格子：玩家走开则打空（可躲）
	TRACK_TARGET,   ## 锁定单位：跟着玩家走（躲不掉）
}

enum IntentKind { ATTACK, MULTI_ATTACK, BUFF, DEBUFF, SUMMON, MOVE, ROTATE, SPECIAL, SLEEP }

# ------------------------------------------------------------------ 地形（§8.3）

enum Terrain { FLOOR, WALL, PIT, RUBBLE, EXIT_GATE }

enum Hazard { NONE, SPIKES, FIRE, ACID, ASH }

enum Feature { NONE, PILLAR, CRATE, TURNSTILE, ALTAR }

# ------------------------------------------------------------------ 战斗流程（§8.4）

enum BattlePhase {
	BATTLE_START,
	ROUND_START,
	PLAYER_PHASE,
	ROUND_END_PLAYER,
	ENEMY_PHASE,
	ROUND_END_ALL,
	EXPLORE,        ## 胜利后的拾取阶段，无限体力，走到 EXIT_GATE 结束
	BATTLE_WIN,
	BATTLE_LOSE,
}

enum Team { PLAYER, ENEMY, NEUTRAL }

# ------------------------------------------------------------------ 状态（§8.9）

enum StackMode { STACK_INTENSITY, STACK_DURATION, REFRESH_DURATION }

enum WinCondition { KILL_ALL, SURVIVE_N, REACH_TILE, PROTECT }

# ------------------------------------------------------------------ 房间（§9.6）

enum RoomType { COMBAT, ELITE, EVENT, SHOP, TREASURE, CAMP, BOSS, ENTRANCE }
