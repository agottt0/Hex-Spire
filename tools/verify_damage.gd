extends SceneTree
## 伤害管线验证 —— §4.4 + §6.5 + R2
## godot --headless --path E:/GameDemo -s res://tools/verify_damage.gd

func _initialize() -> void:
	var fail := 0
	fail += _test_block_absorbs()
	fail += _test_rune_order()
	fail += _test_int_and_floor()
	fail += _test_preview_no_rng()
	fail += _test_r2_scaling()
	fail += _test_backstab_and_dodge()
	print("")
	print("========== 总失败数: %d ==========" % fail)
	quit(0 if fail == 0 else 1)


func _mk_unit(hp: int, atk: int, d: int, agi: int = 0, luk: int = 0, crit: int = 0) -> Unit:
	var u := Unit.new()
	u.id = 1
	u.hp = hp
	u.hp_max = hp
	u.atk = atk
	u.def = d
	u.agi = agi
	u.luk = luk
	u.crit = crit
	u.size_class = GameEnums.SizeClass.S
	u.size_data = SizeClassData.make(GameEnums.SizeClass.S)
	return u


func _ctx(src: Unit, tgt: Unit, flat: float, ratio: float) -> DamageCalculator.Context:
	var c := DamageCalculator.Context.new()
	c.source = src
	c.target = tgt
	c.flat = flat
	c.stat_ref = "ATK"
	c.stat_ratio = ratio
	return c


# ---- 1. ⭐ 已确认的偏离：格挡必须能完全吸收伤害
func _test_block_absorbs() -> int:
	var bad := 0
	var atk := _mk_unit(100, 10, 0)
	var tgt := _mk_unit(100, 0, 0)
	tgt.block = 999
	var rng := RngStreams.new(42)
	var r := DamageCalculator.calculate(_ctx(atk, tgt, 0.0, 1.0), rng)
	print("1) Block=999 时  最终伤害=%d  吸收=%d  打生命=%d" % [r.final, r.to_block, r.to_hp])
	if r.to_hp != 0:
		print("   FAIL 格挡未能完全吸收 —— 骑士被动失去意义")
		bad += 1

	# 格挡不足时应正确溢出
	tgt.block = 4
	var r2 := DamageCalculator.calculate(_ctx(atk, tgt, 0.0, 1.0), rng)
	print("   Block=4 vs 伤害%d  吸收=%d 溢出到生命=%d（应 %d）" % [
		r2.final, r2.to_block, r2.to_hp, r2.final - 4])
	if r2.to_block != 4 or r2.to_hp != r2.final - 4:
		bad += 1

	# 下限：即使伤害算成 0 也至少 K_MIN_DAMAGE
	var weak := _mk_unit(100, 0, 0)
	var tanky := _mk_unit(100, 0, 9999)
	var r3 := DamageCalculator.calculate(_ctx(weak, tanky, 0.0, 1.0), rng)
	print("   极端减伤下最终伤害=%d（应 >= %d）" % [r3.final, K.K_MIN_DAMAGE])
	if r3.final < K.K_MIN_DAMAGE:
		bad += 1
	return bad


# ---- 2. ⭐ §6.5：符文顺序必须改变结果（D6 的免费深度）
func _test_rune_order() -> int:
	var bad := 0
	var atk := _mk_unit(100, 10, 0)
	var tgt := _mk_unit(100, 0, 0)   # DEF=0 便于验算

	# 锐化：+ ATK×0.5 = +5（加区）
	var sharpen := func(v: float, log: Array) -> float:
		var nv: float = v + 5.0
		log.append({"rune": "锐化", "op": "+5", "before": v, "after": nv})
		return nv
	# 倍化：×1.4（乘区）
	var amplify := func(v: float, log: Array) -> float:
		var nv: float = v * 1.4
		log.append({"rune": "倍化", "op": "x1.4", "before": v, "after": nv})
		return nv

	# 槽序 [锐化, 倍化]：(10+5)×1.4 = 21
	var hook_a := func(v: float, log: Array) -> float:
		return amplify.call(sharpen.call(v, log), log)
	# 槽序 [倍化, 锐化]：10×1.4+5 = 19
	var hook_b := func(v: float, log: Array) -> float:
		return sharpen.call(amplify.call(v, log), log)

	var pv_a := DamageCalculator.preview(_ctx(atk, tgt, 0.0, 1.0), hook_a)
	var pv_b := DamageCalculator.preview(_ctx(atk, tgt, 0.0, 1.0), hook_b)
	print("2) 符文顺序（ATK=10, base=10, DEF=0）")
	print("   [锐化,倍化] = %d  (应 21)" % pv_a.x)
	print("   [倍化,锐化] = %d  (应 19)" % pv_b.x)
	if pv_a.x != 21:
		print("   FAIL 槽序A 结果错误")
		bad += 1
	if pv_b.x != 19:
		print("   FAIL 槽序B 结果错误")
		bad += 1
	if pv_a.x == pv_b.x:
		print("   FAIL 顺序不影响结果 —— §6.5「免费深度」归零，D6 失去意义")
		bad += 1
	return bad


# ---- 3. 返回值必须是 int，且无中间 round
func _test_int_and_floor() -> int:
	var bad := 0
	var atk := _mk_unit(100, 7, 0)
	var tgt := _mk_unit(100, 0, 13)
	var rng := RngStreams.new(1)
	var r := DamageCalculator.calculate(_ctx(atk, tgt, 0.0, 1.3), rng)
	var is_int := typeof(r.final) == TYPE_INT and typeof(r.to_hp) == TYPE_INT
	print("3) 返回类型是 int: %s  (final=%d, raw=%.4f)" % [is_int, r.final, r.raw])
	if not is_int:
		bad += 1
	# floor 而非 round：raw=9.9 应得 9
	if r.raw >= 1.0 and r.final != maxi(floori(r.raw), K.K_MIN_DAMAGE):
		print("   FAIL 未使用 floor")
		bad += 1
	return bad


# ---- 4. ⭐ preview 不得消耗 RNG（否则悬停鼠标污染确定性）
func _test_preview_no_rng() -> int:
	var bad := 0
	var atk := _mk_unit(100, 10, 0, 0, 0, 50)  # CRIT=50% 保证会掷骰
	var tgt := _mk_unit(100, 0, 5)
	var rng := RngStreams.new(7)
	var before := rng.draw_count
	for _i in range(100):
		DamageCalculator.preview(_ctx(atk, tgt, 0.0, 1.0))
	var after := rng.draw_count
	print("4) preview ×100 后 RNG draw_count: %d -> %d（应不变）" % [before, after])
	if before != after:
		print("   FAIL preview 消耗了 RNG")
		bad += 1
	# 而 calculate 应该消耗
	DamageCalculator.calculate(_ctx(atk, tgt, 0.0, 1.0), rng)
	print("   calculate 后 draw_count=%d（应增加）" % rng.draw_count)
	if rng.draw_count == after:
		bad += 1
	return bad


# ---- 5. ⭐ R2：ATK×20 后，各卡伤害的【排序】必须不变
func _test_r2_scaling() -> int:
	var bad := 0
	# 模拟 11 张卡的系数（flat, ratio）
	var cards := [
		["攻击", 0.0, 1.0], ["重击", 0.0, 1.8], ["连刺单次", 0.0, 0.5],
		["穿刺投枪", 0.0, 1.1], ["冲撞", 0.0, 0.4], ["点燃", 0.0, 0.3],
		["盾击", 0.0, 0.6],
	]
	var tgt := _mk_unit(9999, 0, 10)

	var order_at := func(atk_val: int) -> Array:
		var src := _mk_unit(100, atk_val, 0)
		var rows: Array = []
		for c in cards:
			var pv := DamageCalculator.preview(_ctx(src, tgt, c[1], c[2]))
			rows.append([c[0], pv.x])
		rows.sort_custom(func(a, b): return a[1] > b[1])
		var names: Array = []
		for r in rows:
			names.append(r[0])
		return names

	var o1: Array = order_at.call(10)
	var o20: Array = order_at.call(200)
	print("5) R2 —— ATK×20 后出牌强度排序")
	print("   ATK=10 : %s" % str(o1))
	print("   ATK=200: %s" % str(o20))
	if o1 != o20:
		print("   FAIL 排序改变 —— 强数值养成冲垮了策略层（R2）")
		bad += 1
	else:
		print("   ✓ 排序一致 —— R2 通过（系数化生效）")
	return bad


# ---- 6. 背击加成 + 背击无法闪避
func _test_backstab_and_dodge() -> int:
	var bad := 0
	var atk := _mk_unit(100, 10, 0)
	var tgt := _mk_unit(100, 0, 0, 100)   # AGI=100 → 闪避应达上限
	var c_front := _ctx(atk, tgt, 0.0, 1.0)
	var c_rear := _ctx(atk, tgt, 0.0, 1.0)
	c_rear.from_rear = true

	var dodge_front := DamageCalculator.dodge_chance(c_front)
	var dodge_rear := DamageCalculator.dodge_chance(c_rear)
	print("6) 闪避率 正面=%.2f  背击=%.2f（背击应为 0，§8.2.3）" % [dodge_front, dodge_rear])
	if dodge_rear != 0.0:
		print("   FAIL 背击仍可被闪避")
		bad += 1
	if dodge_front <= 0.0:
		print("   FAIL AGI=100 应有闪避率")
		bad += 1

	var pv_front := DamageCalculator.preview(c_front)
	var pv_rear := DamageCalculator.preview(c_rear)
	print("   伤害 正面=%d  背击=%d（背击应更高）" % [pv_front.x, pv_rear.x])
	if pv_rear.x <= pv_front.x:
		bad += 1
	return bad
