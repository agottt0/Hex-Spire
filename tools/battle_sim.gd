extends SceneTree
## 无渲染批量战斗模拟器 —— §17-M0 的核心验证工具
##
## ⚠️ 不依赖任何 autoload（数据用 ContentLibrary 自建）——
##    这样 `godot --headless -s` 一定能跑，也证明了纪律 3 是真的成立。
##
## 用法：
##   godot --headless --path . -s res://tools/battle_sim.gd -- \
##         --battles=1000 --seed=1 --hero=knight --layout=open_hall \
##         --encounter=enc_01 --atk-mult=1 --verify-determinism
##
## 输出指标（M0 判据的量化）：
##   win_rate / avg_rounds
##   rule_violation_count      R7：必须是"被闸住"而非 hang
##   overflow_count            |int| > 2^30 或 inf/nan
##   timeout_count             回合数 > MAX_ROUNDS_PER_BATTLE
##   sequence_repeat_rate      R1'：与上回合出牌序列相同的回合占比
##   reshuffles_per_battle     §7.4.4 的"每 2–4 回合洗一次"验证

var battles := 200
var base_seed := 1
var hero_id := "knight"
var layout_id := "open_hall"
var encounter_id := "enc_01"
var atk_mult := 1
var verify_determinism := false
var report_path := ""
var verbose := false


func _initialize() -> void:
	_parse_args()

	print("=== battle_sim ===")
	print("battles=%d seed=%d hero=%s layout=%s encounter=%s atk_mult=%d" % [
		battles, base_seed, hero_id, layout_id, encounter_id, atk_mult])
	print("")

	var stats := {
		"battles": 0, "wins": 0, "losses": 0, "unfinished": 0,
		"total_rounds": 0, "total_actions": 0,
		"violations": 0, "violation_kinds": {},
		"overflow": 0, "timeout": 0,
		"repeat_rounds": 0, "total_played_rounds": 0,
		"reshuffles": 0,
		"determinism_mismatch": 0,
		"invariant_broken": 0,
	}

	for i in range(battles):
		var seed_i := base_seed + i
		var r := _run_one(seed_i)
		_accumulate(stats, r)

		if verify_determinism:
			var r2 := _run_one(seed_i)
			if r["hash"] != r2["hash"]:
				stats["determinism_mismatch"] += 1
				if stats["determinism_mismatch"] <= 3:
					print("  ⚠️ seed=%d 两次运行哈希不一致: %d vs %d" % [seed_i, r["hash"], r2["hash"]])
					_print_first_divergence(r["log"], r2["log"])

	_report(stats)


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		var key := kv[0].lstrip("-")
		var val := kv[1] if kv.size() > 1 else "1"
		match key:
			"battles": battles = int(val)
			"seed": base_seed = int(val)
			"hero": hero_id = val
			"layout": layout_id = val
			"encounter": encounter_id = val
			"atk-mult": atk_mult = int(val)
			"verify-determinism": verify_determinism = true
			"report": report_path = val
			"verbose": verbose = true


## 跑一场。返回 {won, rounds, actions, violations, hash, log, ...}
func _run_one(seed_value: int) -> Dictionary:
	# ⚠️ 必须重置 uid 计数器，否则跑多场后 uid 递增会让哈希不一致（误报不确定）
	CardInstance.reset_uid_counter()

	var setup := BattleSetup.create(hero_id, layout_id, encounter_id, seed_value)
	var state: BattleState = setup["state"]
	var flow: BattleFlow = setup["flow"]
	var deck: Array = setup["deck"]

	# R2 实验开关：把 ATK 乘 N，验证最优出牌顺序是否改变
	if atk_mult != 1:
		var p := state.player()
		if p != null:
			p.atk *= atk_mult

	flow.battle_start(deck)

	var prev_sequence := ""
	var repeat_rounds := 0
	var played_rounds := 0
	var invariant_ok := true

	while not state.is_over and state.round_number <= K.MAX_ROUNDS_PER_BATTLE:
		var seq := _play_greedy_round(state, flow)
		if not state.piles.invariant_holds():
			invariant_ok = false
		if seq != "":
			played_rounds += 1
			if seq == prev_sequence:
				repeat_rounds += 1
			prev_sequence = seq
		if state.is_over:
			break
		flow.end_turn()

	var timed_out := not state.is_over
	var overflow := _detect_overflow(state)

	return {
		"won": state.player_won,
		"over": state.is_over,
		"rounds": state.round_number,
		"actions": state.action_log.size(),
		"violations": state.rule_violations,
		"hash": state.action_log_hash(),
		"log": state.action_log,
		"repeat_rounds": repeat_rounds,
		"played_rounds": played_rounds,
		"reshuffles": state.piles.reshuffle_count,
		"timeout": timed_out,
		"overflow": overflow,
		"invariant_ok": invariant_ok,
	}


## 贪心策略：每回合把能打的牌按"预计伤害/费用"降序打完。
## 返回本回合的出牌序列签名（用于 R1' 的重复率统计）。
func _play_greedy_round(state: BattleState, flow: BattleFlow) -> String:
	var played: Array[String] = []
	var guard := 0
	while guard < 20:
		guard += 1
		var best_card: CardInstance = null
		var best_cell := Vector3i.ZERO
		var best_score := -1.0

		# ⚠️ 遍历手牌副本，且按 uid 排序 → 确定性
		var hand_sorted: Array = state.piles.hand.duplicate()
		hand_sorted.sort_custom(func(a: CardInstance, b: CardInstance) -> bool: return a.uid < b.uid)

		for c in hand_sorted:
			var cd: CardData = c.data
			if cd == null:
				continue
			var cost := RuleBook.card_cost(state, c.base_cost())
			if cost > state.energy:
				continue
			var player := state.player()
			if player == null:
				break

			if cd.needs_target():
				var legal := TargetResolver.legal_cells(state, player, cd.target_spec)
				for cell in legal:
					var score := _score_play(state, flow, c, cell, cost)
					if score > best_score:
						best_score = score
						best_card = c
						best_cell = cell
			else:
				var score2 := _score_play(state, flow, c, Vector3i.ZERO, cost)
				if score2 > best_score:
					best_score = score2
					best_card = c
					best_cell = Vector3i.ZERO

		if best_card == null or best_score <= 0.0:
			break
		var cid := best_card.card_id()
		if flow.play_card(best_card, best_cell):
			played.append(cid)
		else:
			break
		if state.is_over:
			break
	return ",".join(played)


## 打分：伤害优先，其次格挡与位移。除以费用做性价比。
func _score_play(state: BattleState, flow: BattleFlow, c: CardInstance, cell: Vector3i, cost: int) -> float:
	var cd: CardData = c.data
	var score := 0.0
	var pv := flow.preview_card_damage(c, cell)
	for uid in pv:
		var e: Dictionary = pv[uid]
		score += float(e["min"]) * float(e["repeat"])
	if score == 0.0:
		match cd.card_type:
			GameEnums.CardType.GUARD:
				score = 3.0
			GameEnums.CardType.MOVE:
				# 靠近敌人有价值（否则近战永远打不到）
				var p := state.player()
				var enemies := state.alive_enemies()
				if p != null and not enemies.is_empty():
					var before := p.distance_to_unit(enemies[0])
					var after := HexFootprint.distance_from(cell, p.footprint(), p.facing, enemies[0].anchor)
					score = 2.0 if after < before else 0.1
			GameEnums.CardType.SKILL:
				score = 2.0
			_:
				score = 0.5
	return score / float(maxi(1, cost))


func _detect_overflow(state: BattleState) -> bool:
	for u in state.units:
		for v in [u.hp, u.hp_max, u.atk, u.def, u.block]:
			if absi(v) > (1 << 30):
				return true
	return false


func _accumulate(stats: Dictionary, r: Dictionary) -> void:
	stats["battles"] += 1
	if r["over"]:
		if r["won"]:
			stats["wins"] += 1
		else:
			stats["losses"] += 1
	else:
		stats["unfinished"] += 1
	stats["total_rounds"] += r["rounds"]
	stats["total_actions"] += r["actions"]
	stats["reshuffles"] += r["reshuffles"]
	stats["repeat_rounds"] += r["repeat_rounds"]
	stats["total_played_rounds"] += r["played_rounds"]
	if r["timeout"]:
		stats["timeout"] += 1
	if r["overflow"]:
		stats["overflow"] += 1
	if not r["invariant_ok"]:
		stats["invariant_broken"] += 1
	for v in r["violations"]:
		stats["violations"] += 1
		var kind: String = v.get("kind", "?")
		stats["violation_kinds"][kind] = stats["violation_kinds"].get(kind, 0) + 1


func _print_first_divergence(a: Array, b: Array) -> void:
	var n := mini(a.size(), b.size())
	for i in range(n):
		if str(a[i]) != str(b[i]):
			print("     首个分歧在动作 #%d:" % i)
			print("       A: %s" % str(a[i]))
			print("       B: %s" % str(b[i]))
			return
	print("     长度不同: %d vs %d" % [a.size(), b.size()])


func _report(stats: Dictionary) -> void:
	var n: int = maxi(1, stats["battles"])
	var played: int = maxi(1, stats["total_played_rounds"])
	var repeat_rate := float(stats["repeat_rounds"]) / float(played)

	print("──────── 结果 ────────")
	print("场次           %d" % stats["battles"])
	print("胜率           %.1f%%  (胜 %d / 负 %d / 未结束 %d)" % [
		100.0 * float(stats["wins"]) / float(n), stats["wins"], stats["losses"], stats["unfinished"]])
	print("平均回合数     %.2f" % (float(stats["total_rounds"]) / float(n)))
	print("平均动作数     %.1f" % (float(stats["total_actions"]) / float(n)))
	print("平均洗回次数   %.2f   (§7.4.4 预期 1–2 次/场)" % (float(stats["reshuffles"]) / float(n)))
	print("")
	print("── R1' 一致性风险 ──")
	print("出牌序列重复率 %.3f   (建议阈值 <= 0.45)  %s" % [
		repeat_rate, "✓" if repeat_rate <= 0.45 else "⚠️ 偏高，战斗可能变成重复连招"])
	print("")
	print("── R7 稳定性 ──")
	print("规则违规总数   %d" % stats["violations"])
	if not (stats["violation_kinds"] as Dictionary).is_empty():
		var kinds: Array = (stats["violation_kinds"] as Dictionary).keys()
		kinds.sort()
		for k in kinds:
			print("   %-22s %d" % [k, stats["violation_kinds"][k]])
	print("数值溢出       %d   %s" % [stats["overflow"], "✓" if stats["overflow"] == 0 else "❌"])
	print("超时(>%d回合)  %d" % [K.MAX_ROUNDS_PER_BATTLE, stats["timeout"]])
	print("牌堆不变量破坏 %d   %s" % [stats["invariant_broken"], "✓" if stats["invariant_broken"] == 0 else "❌"])
	if verify_determinism:
		print("")
		print("── 纪律5 确定性 ──")
		print("哈希不一致     %d   %s" % [
			stats["determinism_mismatch"],
			"✓ 完全确定" if stats["determinism_mismatch"] == 0 else "❌ 存在不确定性"])

	if report_path != "":
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(stats, "  "))
			f.close()
			print("")
			print("报告已写入 %s" % report_path)

	var ok: bool = stats["overflow"] == 0 and stats["invariant_broken"] == 0 \
			and stats["determinism_mismatch"] == 0
	print("")
	print("========== %s ==========" % ("通过" if ok else "存在问题"))
	quit(0 if ok else 1)
