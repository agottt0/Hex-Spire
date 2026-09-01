extends SceneTree
## 平衡矩阵：一次跑完全部组合并输出表格
##
## 这是「平衡回归」的自动化验收器 —— 把"手感"变成退出码。
##
## 用法：
##   godot --headless --path . -s res://tools/verify_balance.gd -- --battles=15
##
## 验收标准（策划案 §17 M0 判据① 的可自动化部分）：
##   · 至少 MIN_TENSION_CELLS 格落在 40%–90% 胜率（"有张力"区间）
##   · 没有任何一格 100% 超时
##   · 没有规则违规 / 数值溢出 / 牌堆不变量破坏

const MIN_TENSION_CELLS := 6
const TENSION_LO := 0.40
const TENSION_HI := 0.90

## 代表性组合（不跑全部 32 格，挑有区分度的）
##
## ⚠️ 刻意【排除 bottleneck（1 格门洞）的全部配对】：
##   1 格门只有 S 体型能过，而玩家出生在下半区、门在 row 4、敌人在上半区
##   → 双方被永久隔开，谁都没有"必须过门"的动机 → 必然超时。
##   这张地图需要配合【替代胜利条件】（§8.10 的"到达出口格"/"存活 N 回合"）
##   才能成立，单纯的"歼灭战"在它上面无意义。
##   已在 content_library.gd 的 layout_bottleneck 注释里记录。
##   → 列为后续待办：实现 win_condition 后再把它加回矩阵。
const MATRIX := [
	["knight", "open_hall", "enc_01"],
	["knight", "open_hall", "enc_02"],
	["knight", "open_hall", "enc_03"],
	["knight", "open_hall", "enc_04"],
	["knight", "narrow_pass", "enc_02"],
	["knight", "narrow_pass", "enc_03"],
	["knight", "spike_cell", "enc_02"],
	["knight", "spike_cell", "enc_04"],
	["giant", "open_hall", "enc_01"],
	["giant", "open_hall", "enc_02"],
	["giant", "open_hall", "enc_03"],
	["giant", "open_hall", "enc_04"],
	["giant", "narrow_pass", "enc_02"],
	["giant", "narrow_pass", "enc_04"],
	["giant", "spike_cell", "enc_03"],
	["giant", "spike_cell", "enc_04"],
]

var battles := 15
var base_seed := 1


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		var key := kv[0].lstrip("-")
		var val := kv[1] if kv.size() > 1 else "1"
		match key:
			"battles": battles = int(val)
			"seed": base_seed = int(val)

	print("=== 平衡矩阵（每格 %d 场，seed=%d）===" % [battles, base_seed])
	print("")
	print("%-8s %-13s %-8s %7s %8s %8s %8s %6s" % [
		"英雄", "地形", "怪物组", "胜率", "平均回合", "玩家掉血", "超时", "违规"])
	print("─".repeat(78))

	var tension := 0
	var timeouts := 0
	var violations := 0
	var invariant_breaks := 0
	var rows: Array = []

	for cfg in MATRIX:
		var r := _run_cell(cfg[0], cfg[1], cfg[2])
		rows.append(r)
		var wr: float = r["win_rate"]
		var mark := ""
		if wr >= TENSION_LO and wr <= TENSION_HI:
			tension += 1
			mark = " ✓"
		if r["timeout_rate"] >= 1.0:
			timeouts += 1
			mark = " ⚠超时"
		violations += r["violations"]
		invariant_breaks += r["invariant_breaks"]
		print("%-8s %-13s %-8s %6.0f%% %8.2f %8.1f %7.0f%% %6d%s" % [
			cfg[0], cfg[1], cfg[2], wr * 100.0, r["avg_rounds"],
			r["avg_hp_lost"], r["timeout_rate"] * 100.0, r["violations"], mark])

	print("─".repeat(78))
	print("")
	print("张力格（40–90%% 胜率）: %d / %d   （标准 >= %d）" % [
		tension, MATRIX.size(), MIN_TENSION_CELLS])
	print("100%% 超时格: %d   （标准 = 0）" % timeouts)
	print("规则违规总数: %d   （标准 = 0）" % violations)
	print("牌堆不变量破坏: %d   （标准 = 0）" % invariant_breaks)

	var ok := tension >= MIN_TENSION_CELLS and timeouts == 0 \
			and violations == 0 and invariant_breaks == 0
	print("")
	print("========== %s ==========" % ("平衡验收通过" if ok else "平衡未达标"))
	quit(0 if ok else 1)


func _run_cell(hero: String, layout: String, enc: String) -> Dictionary:
	var wins := 0
	var total_rounds := 0
	var total_hp_lost := 0
	var timeouts := 0
	var violations := 0
	var invariant_breaks := 0

	for i in range(battles):
		CardInstance.reset_uid_counter()
		var setup := BattleSetup.create(hero, layout, enc, base_seed + i)
		var state: BattleState = setup["state"]
		var flow: BattleFlow = setup["flow"]
		var start_hp := 0
		var p0 := state.player()
		if p0 != null:
			start_hp = p0.hp
		flow.battle_start(setup["deck"])

		while not state.is_over and state.round_number <= K.MAX_ROUNDS_PER_BATTLE:
			_greedy_round(state, flow)
			if not state.piles.invariant_holds():
				invariant_breaks += 1
			if state.is_over:
				break
			flow.end_turn()

		if not state.is_over:
			timeouts += 1
		elif state.player_won:
			wins += 1
		total_rounds += state.round_number
		var p := state.player()
		if p != null:
			total_hp_lost += maxi(0, start_hp - p.hp)
		violations += state.rule_violations.size()

	var n := maxi(1, battles)
	return {
		"win_rate": float(wins) / float(n),
		"avg_rounds": float(total_rounds) / float(n),
		"avg_hp_lost": float(total_hp_lost) / float(n),
		"timeout_rate": float(timeouts) / float(n),
		"violations": violations,
		"invariant_breaks": invariant_breaks,
	}


## 与 battle_sim 一致的贪心策略（保持两个工具结论可比）
func _greedy_round(state: BattleState, flow: BattleFlow) -> void:
	var guard := 0
	while guard < 20:
		guard += 1
		var best: CardInstance = null
		var best_cell := Vector3i.ZERO
		var best_score := -1.0
		var hand: Array = state.piles.hand.duplicate()
		hand.sort_custom(func(a: CardInstance, b: CardInstance) -> bool: return a.uid < b.uid)
		for c in hand:
			var cd: CardData = c.data
			if cd == null:
				continue
			var cost := RuleBook.card_cost(state, c.base_cost())
			if cost > state.energy:
				continue
			var p := state.player()
			if p == null:
				return
			if cd.needs_target():
				for cell in TargetResolver.legal_cells(state, p, cd.target_spec):
					var sc := _score(state, flow, c, cell, cost)
					if sc > best_score:
						best_score = sc
						best = c
						best_cell = cell
			else:
				var sc2 := _score(state, flow, c, Vector3i.ZERO, cost)
				if sc2 > best_score:
					best_score = sc2
					best = c
					best_cell = Vector3i.ZERO
		if best == null or best_score <= 0.0:
			return
		if not flow.play_card(best, best_cell):
			return
		if state.is_over:
			return


func _score(state: BattleState, flow: BattleFlow, c: CardInstance, cell: Vector3i, cost: int) -> float:
	var cd: CardData = c.data
	var score := 0.0
	var pv := flow.preview_card_damage(c, cell)
	for uid in pv:
		score += float(pv[uid]["min"]) * float(pv[uid]["repeat"])
	if score == 0.0:
		match cd.card_type:
			GameEnums.CardType.GUARD:
				score = 3.0
			GameEnums.CardType.MOVE:
				var p := state.player()
				var en := state.alive_enemies()
				if p != null and not en.is_empty():
					var before := p.distance_to_unit(en[0])
					var after := HexFootprint.distance_from(cell, p.footprint(), p.facing, en[0].anchor)
					score = 2.0 if after < before else 0.1
			GameEnums.CardType.SKILL:
				score = 2.0
			_:
				score = 0.5
	return score / float(maxi(1, cost))
