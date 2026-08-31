class_name DamageCalculator
## §4.4 伤害管线的【唯一实现】。禁止在别处算伤害。
##
## ══════════════════════════════════════════════════════════════════
## 管线阶段（⚠️ 顺序有讲究，读完注释再改）
## ══════════════════════════════════════════════════════════════════
##   ①  基础     flat + stats[stat_ref] × ratio          （§7.5 强制系数化）
##   ②  平坦加成  非符文来源（状态、装备 base），可求和
##   ②′ 顺序钩子  TriggerBus.emit(ON_ATTACK)：符文槽 1→6 依次 += 或 *=
##   ③  乘区     非符文乘区 × Π(1+x)（易伤等），可求积
##   ④  暴击     × (1 + K_CRIT_BASE + LUK×K_LUK_TO_CRITDMG)
##   ⑤  减伤     × (1 - DEF/(DEF+K_DEF_SOFTCAP))
##   ⑤′ 取整下限  maxi(floori(v), K_MIN_DAMAGE)  → 此后全 int
##   ⑥  扣格挡    先扣 block，溢出打 hp
##
## ── 为什么有 ②′ ─────────────────────────────────────────────
## §4.4 要求"加法全做完再乘"，但 §6.5 要求 [锐化,倍化] ≠ [倍化,锐化]。
## 桶式聚合（先求和所有加区再求积所有乘区）会让顺序失效，D6 的免费深度归零。
## 所以在 ② 与 ③ 之间开一个【顺序敏感】阶段，符文在这里按槽位依次作用于
## running value。ATK=10、base=10 时：
##    [锐化,倍化] = (10+5)×1.4 = 21
##    [倍化,锐化] = 10×1.4+5   = 19
## 这个差异必须在 UI 上肉眼可见 —— 它是 §6.5"免费深度"的最小可证形态。
##
## ── 为什么 ⑤′ 在 ⑥ 之前（已确认偏离策划案字面顺序）─────────────
## §4.4 原文把下限写在扣格挡【之后】。按字面实现会导致：
##   Block=999 时仍然掉 K_MIN 血 → 格挡永远无法完全吸收一次攻击
##   → 骑士的「格挡不清空」被动失去意义，"堆防御"不再是一条真路线。
## "保证永远能破防"针对的是 DEF 软曲线（⑤），不是 Block（⑥）。
## 用户已确认采用本顺序。见 K.K_MIN_DAMAGE 的注释。
##
## ── 为什么分 calculate / preview 两个入口 ────────────────────
## §13.2 要求悬停显示"预计伤害 X（暴击 Y）"。若预览走同一函数就会消耗 RNG，
## 导致"鼠标划过战场"污染确定性，并连带打爆 Undo 的撤销屏障。
## 所以 preview() 【不接受 rng 参数】，返回 [不暴, 暴] 区间。


## 伤害计算的输入。用纯数据传递，便于 preview 复用。
class Context:
	var source: Unit = null
	var target: Unit = null
	## ① 的系数化参数（§7.5）
	var flat: float = 0.0
	var stat_ref: String = "ATK"
	var stat_ratio: float = 0.0
	## ② 非符文平坦加成
	var flat_bonus: float = 0.0
	## ③ 非符文乘区（每项是 x，最终 ×Π(1+x)）
	var multipliers: Array[float] = []
	## 是否来自背击（§8.2.3：加成 + 无法闪避）
	var from_rear: bool = false
	## 是否忽略部分 DEF（如法师的《奥术飞弹》无视 1 点 DEF）
	var def_ignore: int = 0
	## 标签，供符文条件过滤（"近战"/"火焰"…）
	var tags: Array[String] = []
	## 触发上下文标记，用于日志
	var tag: String = ""


## 计算结果
class Result:
	var raw: float = 0.0          ## ⑤′ 取整前的值，仅供调试
	var final: int = 0            ## 最终伤害（int）
	var to_block: int = 0         ## 被格挡吸收的部分
	var to_hp: int = 0            ## 实际扣的生命
	var is_crit: bool = false
	var is_dodged: bool = false
	var rune_log: Array = []      ## ②′ 每一步的记录，供符文实验室与调试

	func to_dict() -> Dictionary:
		return {
			"final": final, "to_block": to_block, "to_hp": to_hp,
			"crit": is_crit, "dodged": is_dodged, "rune_log": rune_log,
		}


## 取属性值。stat_ref 为空或 "NONE" 时视为 0（纯 flat 伤害）。
static func _stat_of(u: Unit, ref: String) -> int:
	if u == null:
		return 0
	match ref.to_upper():
		"ATK": return u.atk
		"DEF": return u.def
		"AGI": return u.agi
		"LUK": return u.luk
		"CRIT": return u.crit
		"HP": return u.hp
		"HP_MAX": return u.hp_max
		_: return 0


## ①+② —— 不含符文、不含暴击、不含减伤的"账面基数"
static func base_value(ctx: Context) -> float:
	var v := ctx.flat + float(_stat_of(ctx.source, ctx.stat_ref)) * ctx.stat_ratio
	v += ctx.flat_bonus
	return v


## ③ 非符文乘区
static func _apply_multipliers(v: float, ctx: Context) -> float:
	var out := v
	for m in ctx.multipliers:
		out *= (1.0 + m)
	if ctx.from_rear:
		out *= (1.0 + K.BACKSTAB_MULT)
	return out


## ⑤ 减伤：DEF 软曲线（§4.4）
static func _apply_defense(v: float, ctx: Context) -> float:
	if ctx.target == null:
		return v
	var d := maxf(0.0, float(ctx.target.def - ctx.def_ignore))
	var reduction := d / (d + K.K_DEF_SOFTCAP)
	return v * (1.0 - reduction)


## ④ 暴击倍率
static func crit_multiplier(source: Unit) -> float:
	if source == null:
		return 1.0
	return 1.0 + K.K_CRIT_BASE_MULT + float(source.luk) * K.K_LUK_TO_CRIT_DMG


## 闪避率（§4.3：AGI 的次要作用）。背击无法被闪避（§8.2.3）。
static func dodge_chance(ctx: Context) -> float:
	if ctx.target == null or ctx.from_rear:
		return 0.0
	return minf(float(ctx.target.agi) * K.K_AGI_TO_DODGE, K.K_DODGE_CAP)


## ══════════════════════════════════════════════════════════════
## 正式计算。会消耗 RNG（暴击、闪避判定）。
##
## rune_hook: 可选的 Callable(running_value: float, log: Array) -> float
##            由 TriggerBus 在 ②′ 提供。传 null 则跳过 ②′。
## ══════════════════════════════════════════════════════════════
static func calculate(ctx: Context, rng: RngStreams, rune_hook: Callable = Callable()) -> Result:
	var r := Result.new()

	# 闪避判定（先判，闪避则完全不结算）
	var dodge := dodge_chance(ctx)
	if dodge > 0.0 and rng != null and rng.chance(rng.combat, dodge):
		r.is_dodged = true
		return r

	# ① + ②
	var v := base_value(ctx)

	# ②′ 顺序钩子 —— 符文按槽位 1→6 依次作用
	if rune_hook.is_valid():
		v = rune_hook.call(v, r.rune_log)

	# ③
	v = _apply_multipliers(v, ctx)

	# ④ 暴击
	if rng != null and ctx.source != null:
		var crit_p := float(ctx.source.crit) / 100.0
		if crit_p > 0.0 and rng.chance(rng.combat, crit_p):
			r.is_crit = true
			v *= crit_multiplier(ctx.source)

	# ⑤ 减伤
	v = _apply_defense(v, ctx)
	r.raw = v

	# ⑤′ 取整 + 下限（⚠️ 在扣格挡之前，见文件头注释）
	r.final = maxi(floori(v), K.K_MIN_DAMAGE)

	# ⑥ 扣格挡，溢出打生命
	if ctx.target != null:
		r.to_block = mini(r.final, ctx.target.block)
		r.to_hp = r.final - r.to_block
	else:
		r.to_hp = r.final

	return r


## ══════════════════════════════════════════════════════════════
## 预览：返回 [不暴击伤害, 暴击伤害]。
## ⚠️ 【不消耗 RNG】—— 悬停鼠标不得影响确定性（见文件头注释）。
## ══════════════════════════════════════════════════════════════
static func preview(ctx: Context, rune_hook: Callable = Callable()) -> Vector2i:
	var v := base_value(ctx)
	if rune_hook.is_valid():
		var dummy_log: Array = []
		v = rune_hook.call(v, dummy_log)
	v = _apply_multipliers(v, ctx)

	var normal := _apply_defense(v, ctx)
	var crit := _apply_defense(v * crit_multiplier(ctx.source), ctx)

	return Vector2i(
		maxi(floori(normal), K.K_MIN_DAMAGE),
		maxi(floori(crit), K.K_MIN_DAMAGE)
	)


## 格挡获取量（§4.4：GAIN_BLOCK 也走系数化）
static func calculate_block(source: Unit, flat: float, stat_ref: String, ratio: float) -> int:
	var v := flat + float(_stat_of(source, stat_ref)) * ratio
	return maxi(0, floori(v))
