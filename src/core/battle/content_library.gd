class_name ContentLibrary
## P1 的内容数据（代码内建，不依赖 .tres）
##
## 为什么先用代码而不是 .tres：
##   · battle_sim 与单测可以零依赖地构造内容（不需要 Database autoload）
##   · 灰盒期改数值就是改这个文件，比编辑器点 .tres 快
##   · 数值全部走 §7.5 系数化（flat + stat_ref × ratio），
##     所以"改成 .tres"随时可做，结构完全一致
##
## P2 之后若策划要自己调，用 tools/ 里的导出脚本一次性生成 .tres 即可。


# ══════════════════════════════════════════════════════ 英雄

static func knight() -> HeroData:
	var h := HeroData.new()
	h.id = "knight"
	h.display_name = "骑士"
	h.size_class = GameEnums.SizeClass.S
	h.base_hp = 80
	h.base_atk = 10
	h.base_def = 8
	h.base_agi = 6
	h.base_luk = 5
	h.base_crit = 10
	h.energy_max = 5
	h.cards_drawn_per_turn = 5
	h.cornerstone_card_ids = ["shield_bash", "def_basic", "move_basic"]
	h.card_pool_tags = ["守备", "反击", "嘲讽", "位移抗性"]
	# 被动：格挡不在回合结束清空 → 滚雪球型坦克（§4.2）
	h.passive_rules = {GameEnums.GameRule.BLOCK_PERSISTS: true}
	h.passive_text = "格挡不在回合结束清空"
	return h


static func giant() -> HeroData:
	var h := HeroData.new()
	h.id = "giant"
	h.display_name = "巨人"
	h.size_class = GameEnums.SizeClass.M      # ⭐ D8 在玩家侧的载体
	h.base_hp = 110
	h.base_atk = 12
	h.base_def = 6
	h.base_agi = 3
	h.base_luk = 4
	h.base_crit = 5
	h.energy_max = 5
	h.cards_drawn_per_turn = 5
	h.cornerstone_card_ids = ["atk_basic", "boulder_body", "move_basic"]
	h.card_pool_tags = ["范围溅射", "推拉", "地形改造", "控场"]
	h.passive_rules = {GameEnums.GameRule.KNOCKBACK_IMMUNE: true}
	h.passive_text = "无法被击退；可碾压穿过比自己小的单位"
	return h


static func all_heroes() -> Array[HeroData]:
	return [knight(), giant()]


static func hero_by_id(hid: String) -> HeroData:
	for h in all_heroes():
		if h.id == hid:
			return h
	return knight()


# ══════════════════════════════════════════════════════ 卡牌
# ⚠️ 全部严格 flat + stat_ref × ratio（§7.5）。离散量（格数/层数/抽牌数）不缩放。

static func _card(
	cid: String, name: String, ctype: GameEnums.CardType, cost: int,
	spec: TargetSpec, effects: Array[EffectStep], tags: Array[String] = []
) -> CardData:
	var c := CardData.new()
	c.id = cid
	c.display_name = name
	c.card_type = ctype
	c.energy_cost = cost
	c.target_spec = spec
	c.effects = effects
	c.tags = tags
	return c


static func all_cards() -> Array[CardData]:
	var out: Array[CardData] = []

	# ---- 三张基石卡（§7.2）
	out.append(_card("atk_basic", "攻击", GameEnums.CardType.ATTACK, 1,
		TargetSpec.make(GameEnums.TargetShape.SINGLE, 1, 1),
		[EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "ATK", 1.0)],
		["近战"]))

	out.append(_card("def_basic", "防御", GameEnums.CardType.GUARD, 1,
		TargetSpec.self_target(),
		[EffectStep.make(GameEnums.EffectOp.GAIN_BLOCK, 2.0, "DEF", 1.0)],
		["格挡"]))

	var mv := EffectStep.make(GameEnums.EffectOp.MOVE_SELF)
	mv.distance = 2
	out.append(_card("move_basic", "移动", GameEnums.CardType.MOVE, 1,
		TargetSpec.make(GameEnums.TargetShape.TILE, 1, 2, 0, false),
		[mv], ["位移"]))

	# ---- 英雄基石变体
	# 骑士《盾击》：伤害受 DEF 加成 + 击退 1 格 → 让"堆 DEF"是一条真路线
	var sb_dmg := EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "ATK", 0.6)
	var sb_def := EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "DEF", 0.8)
	var sb_kb := EffectStep.make(GameEnums.EffectOp.KNOCKBACK)
	sb_kb.distance = 1
	out.append(_card("shield_bash", "盾击", GameEnums.CardType.ATTACK, 1,
		TargetSpec.make(GameEnums.TargetShape.SINGLE, 1, 1),
		[sb_dmg, sb_def, sb_kb], ["近战", "位移"]))

	# 巨人《巨岩之躯》：格挡 + 相邻敌人缓迟 → M 体型的"我就是障碍物"
	var bb_block := EffectStep.make(GameEnums.EffectOp.GAIN_BLOCK, 2.0, "DEF", 1.0)
	var bb_slow := EffectStep.make(GameEnums.EffectOp.APPLY_STATUS)
	bb_slow.status_id = "chill"
	bb_slow.status_stacks = 1
	out.append(_card("boulder_body", "巨岩之躯", GameEnums.CardType.GUARD, 1,
		TargetSpec.make(GameEnums.TargetShape.ADJACENT_ALL, 0, 1, 0, false),
		[bb_block, bb_slow], ["格挡", "控场"]))

	# ---- 8 张普通卡
	out.append(_card("heavy_strike", "重击", GameEnums.CardType.ATTACK, 2,
		TargetSpec.make(GameEnums.TargetShape.SINGLE, 1, 1),
		[EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "ATK", 1.8)],
		["近战"]))

	# 《连刺》repeat=3 → ON_ATTACK 触发 3 次，是 R7 的压力来源
	out.append(_card("multi_stab", "连刺", GameEnums.CardType.ATTACK, 1,
		TargetSpec.make(GameEnums.TargetShape.SINGLE, 1, 1),
		[EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "ATK", 0.5, 3)],
		["近战", "连击"]))

	out.append(_card("pierce_javelin", "穿刺投枪", GameEnums.CardType.ATTACK, 2,
		TargetSpec.make(GameEnums.TargetShape.LINE, 1, 3, 3, true),
		[EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "ATK", 1.1)],
		["远程", "范围"]))

	out.append(_card("iron_wall", "铁壁", GameEnums.CardType.GUARD, 2,
		TargetSpec.self_target(),
		[EffectStep.make(GameEnums.EffectOp.GAIN_BLOCK, 4.0, "DEF", 1.5)],
		["格挡"]))

	# 《冲撞》：位移即伤害（§8.6）
	var ch_dash := EffectStep.make(GameEnums.EffectOp.DASH)
	ch_dash.distance = 3
	var ch_dmg := EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "ATK", 0.4)
	var ch_kb := EffectStep.make(GameEnums.EffectOp.KNOCKBACK)
	ch_kb.distance = 2
	out.append(_card("charge", "冲撞", GameEnums.CardType.ATTACK, 1,
		TargetSpec.make(GameEnums.TargetShape.TILE, 1, 3, 0, false),
		[ch_dash, ch_dmg, ch_kb], ["位移", "近战"]))

	var ig_dmg := EffectStep.make(GameEnums.EffectOp.DEAL_DAMAGE, 0.0, "ATK", 0.3)
	var ig_burn := EffectStep.make(GameEnums.EffectOp.APPLY_STATUS)
	ig_burn.status_id = "burn"
	ig_burn.status_stacks = 3
	out.append(_card("ignite", "点燃", GameEnums.CardType.SKILL, 1,
		TargetSpec.make(GameEnums.TargetShape.SINGLE, 1, 2),
		[ig_dmg, ig_burn], ["火焰", "状态"]))

	var draw2 := EffectStep.make(GameEnums.EffectOp.DRAW_CARD)
	draw2.repeat = 2
	out.append(_card("quick_plan", "急谋", GameEnums.CardType.SKILL, 0,
		TargetSpec.self_target(), [draw2], ["抽牌"]))

	var dash2 := EffectStep.make(GameEnums.EffectOp.MOVE_SELF)
	dash2.distance = 2
	out.append(_card("gust_step", "疾风步", GameEnums.CardType.MOVE, 0,
		TargetSpec.make(GameEnums.TargetShape.TILE, 1, 2, 0, false),
		[dash2], ["位移"]))

	return out


static func card_by_id(cid: String) -> CardData:
	for c in all_cards():
		if c.id == cid:
			return c
	return null


## 构造某英雄的初始卡组（11 张 —— §7.4.4 的最坏情形，R1' 测得准）
static func starting_deck(hero: HeroData) -> Array[CardInstance]:
	var ids: Array[String] = []
	for cid in hero.cornerstone_card_ids:
		ids.append(cid)
	for cid in ["heavy_strike", "multi_stab", "pierce_javelin", "iron_wall",
				"charge", "ignite", "quick_plan", "gust_step"]:
		ids.append(cid)
	var out: Array[CardInstance] = []
	for cid in ids:
		var cd := card_by_id(cid)
		if cd != null:
			out.append(CardInstance.new(cd))
	return out


# ══════════════════════════════════════════════════════ 敌人

static func _enemy(
	eid: String, name: String, size: GameEnums.SizeClass,
	hp: int, atk: int, d: int, agi: int,
	ai: GameEnums.AIProfile, targeting: GameEnums.IntentTargeting
) -> EnemyData:
	var e := EnemyData.new()
	e.id = eid
	e.display_name = name
	e.size_class = size
	e.base_hp = hp
	e.base_atk = atk
	e.base_def = d
	e.base_agi = agi
	e.ai_profile = ai
	e.intent_targeting = targeting
	return e


static func all_enemies() -> Array[EnemyData]:
	var out: Array[EnemyData] = []

	# 打空型：玩家走开就落空（可躲）
	out.append(_enemy("biting_hound", "扑咬犬", GameEnums.SizeClass.S,
		24, 8, 2, 8,
		GameEnums.AIProfile.AGGRESSIVE, GameEnums.IntentTargeting.FIXED_TILE))

	# 追踪型：躲不掉，但可以断视线
	out.append(_enemy("stone_slinger", "投石手", GameEnums.SizeClass.S,
		18, 6, 1, 5,
		GameEnums.AIProfile.RANGED_KITER, GameEnums.IntentTargeting.TRACK_TARGET))

	# M 体型：相邻格多、转向慢 → 绕后价值高
	var golem := _enemy("stone_golem", "石傀", GameEnums.SizeClass.M,
		60, 10, 6, 4,
		GameEnums.AIProfile.BLOCKER, GameEnums.IntentTargeting.FIXED_TILE)
	golem.is_elite = true
	out.append(golem)

	# L 体型：免疫击退、可碾压
	var worm := _enemy("siege_worm", "攻城虫", GameEnums.SizeClass.L,
		120, 14, 8, 2,
		GameEnums.AIProfile.BOSS_PHASED, GameEnums.IntentTargeting.FIXED_TILE)
	worm.is_boss = true
	worm.knockback_resist_override = 999
	out.append(worm)

	return out


static func enemy_by_id(eid: String) -> EnemyData:
	for e in all_enemies():
		if e.id == eid:
			return e
	return null


# ══════════════════════════════════════════════════════ 地形模板

## 空旷厅堂：全 FLOOR，出口在 (4,7)
static func layout_open_hall() -> HexGrid:
	var g := HexGrid.new()
	g.set_terrain(HexCoord.offset_to_cube(4, 7), GameEnums.Terrain.EXIT_GATE)
	return g


## 狭道·2格门：M 能过且能堵死，L 过不去（已用寻路验证）
static func layout_narrow_pass() -> HexGrid:
	var g := HexGrid.new()
	for col in range(1, 8):
		if col == 3 or col == 4:
			continue
		g.set_terrain(HexCoord.offset_to_cube(col, 4), GameEnums.Terrain.WALL)
	g.set_terrain(HexCoord.offset_to_cube(4, 7), GameEnums.Terrain.EXIT_GATE)
	return g


## 狭道·1格门：只有 S 能过（真正的体型闸门）
static func layout_bottleneck() -> HexGrid:
	var g := HexGrid.new()
	for col in range(1, 8):
		if col == 4:
			continue
		g.set_terrain(HexCoord.offset_to_cube(col, 4), GameEnums.Terrain.WALL)
	g.set_terrain(HexCoord.offset_to_cube(4, 7), GameEnums.Terrain.EXIT_GATE)
	return g


## 尖刺牢房。
## ⚠️ 尖刺位置是算过的：L 在 (4,1) facing=2 占
##   {(4,1)(3,2)(4,2)(3,3)(4,3)(5,3)}，与下列 6 个尖刺格无交集 ——
##   避免"L 英雄一出生就踩多格 hazard 各结算一次"（§8.2.2 机制点 7）
static func layout_spike_cell() -> HexGrid:
	var g := HexGrid.new()
	g.set_terrain(HexCoord.offset_to_cube(2, 4), GameEnums.Terrain.WALL)
	g.set_terrain(HexCoord.offset_to_cube(6, 4), GameEnums.Terrain.WALL)
	for cell in [[2, 3], [6, 3], [4, 4], [3, 5], [5, 5], [4, 6]]:
		g.set_hazard(HexCoord.offset_to_cube(cell[0], cell[1]), GameEnums.Hazard.SPIKES)
	g.set_terrain(HexCoord.offset_to_cube(4, 7), GameEnums.Terrain.EXIT_GATE)
	return g


static func layout_by_id(lid: String) -> HexGrid:
	match lid:
		"narrow_pass": return layout_narrow_pass()
		"bottleneck": return layout_bottleneck()
		"spike_cell": return layout_spike_cell()
		_: return layout_open_hall()


static func all_layout_ids() -> Array[String]:
	return ["open_hall", "narrow_pass", "bottleneck", "spike_cell"]


# ══════════════════════════════════════════════════════ 怪物组

## 返回 [{enemy_id, count}]
static func encounter(eid: String) -> Array:
	match eid:
		"enc_01": return [{"enemy_id": "biting_hound", "count": 1}]
		"enc_02": return [{"enemy_id": "biting_hound", "count": 2},
						  {"enemy_id": "stone_slinger", "count": 1}]
		"enc_03": return [{"enemy_id": "stone_golem", "count": 1},
						  {"enemy_id": "biting_hound", "count": 2}]
		"enc_04": return [{"enemy_id": "siege_worm", "count": 1},
						  {"enemy_id": "stone_slinger", "count": 1}]
		_: return [{"enemy_id": "biting_hound", "count": 1}]


static func all_encounter_ids() -> Array[String]:
	return ["enc_01", "enc_02", "enc_03", "enc_04"]
