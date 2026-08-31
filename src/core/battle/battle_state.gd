class_name BattleState
extends RefCounted
## 战斗全状态 —— §14.1 battle_state.gd
##
## 纯逻辑、零 Node 依赖（纪律 3）、可序列化（纪律 2/5）。
##
## ⚠️ 事件不走 EventBus，而是追加到 event_log（纯数据）。
##    battle_scene.gd 每帧 drain 并转发。这让 core 能在无渲染下跑完 ——
##    battle_sim 与全部单测的前提，也让纪律 3 是【字面成立】而非靠自觉。
##
## ⚠️ RNG 通过构造参数【注入】，core 不引用 RNGService autoload（纪律 1/3）。

var grid: HexGrid = null
var piles: PileManager = null
var rng: RngStreams = null
var queue: ActionQueue = null

## ⚠️ 单位用【显式排序的数组】而非 Dictionary 遍历（纪律 5）
var units: Array[Unit] = []
var _next_unit_id: int = 1

var player_unit_id: int = -1

# ---- 回合与阶段
var phase: GameEnums.BattlePhase = GameEnums.BattlePhase.BATTLE_START
var round_number: int = 0
var energy: int = 0
var cards_played_this_round: int = 0

# ---- 英雄基线（RuleBook 的 fallback 值）
var hero_energy_max_base: int = 5
var hero_draw_base: int = 5
var deck_capacity_base: int = 20

## 符文/装备聚合后的规则值。⚠️ 只允许 RuleBook 读取（§15.6 单消费点）
var rule_agg: Dictionary = {}

## R7 的产出：被闸住的违规记录。battle_sim 靠它统计死循环而非崩溃
var rule_violations: Array = []

## 纯数据事件流（纪律 3）
var event_log: Array = []

## 完整动作日志。确定性验证靠它做哈希比对（纪律 5）
var action_log: Array = []

## 触发总线（P4 接入符文后才有监听者，P1 只 emit）
var trigger_bus = null

## 战斗结果
var win_condition: GameEnums.WinCondition = GameEnums.WinCondition.KILL_ALL
var is_over: bool = false
var player_won: bool = false


func _init(p_rng: RngStreams = null) -> void:
	grid = HexGrid.new()
	piles = PileManager.new()
	rng = p_rng if p_rng != null else RngStreams.new(0)
	queue = ActionQueue.new()


# ------------------------------------------------------------------ 单位管理

## 加入单位并登记占格。返回 false 表示放不下（调用方需处理，如走 fallback_enemies）
func add_unit(u: Unit, anchor: Vector3i, facing: int) -> bool:
	if not HexFootprint.can_place(grid, anchor, u.footprint(), facing, -1, u.can_crush_rubble()):
		return false
	u.id = _next_unit_id
	_next_unit_id += 1
	u.anchor = anchor
	u.facing = facing
	units.append(u)
	grid.set_occupancy(u.id, u.cells())
	if u.team == GameEnums.Team.PLAYER and player_unit_id < 0:
		player_unit_id = u.id
	log_event("unit_spawned", u.to_dict())
	return true


func unit_by_id(uid: int) -> Unit:
	for u in units:
		if u.id == uid:
			return u
	return null


func player() -> Unit:
	return unit_by_id(player_unit_id)


## 存活单位，按 id 升序（确定性）
func alive_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for u in units:
		if u.is_alive:
			out.append(u)
	out.sort_custom(func(a: Unit, b: Unit) -> bool: return a.id < b.id)
	return out


func alive_enemies() -> Array[Unit]:
	var out: Array[Unit] = []
	for u in alive_units():
		if u.team == GameEnums.Team.ENEMY:
			out.append(u)
	return out


## 敌人行动顺序：AGI 降序 + id tiebreak（§8.4 + 纪律 5 的显式排序要求）
func enemies_in_action_order() -> Array[Unit]:
	var out := alive_enemies()
	out.sort_custom(func(a: Unit, b: Unit) -> bool:
		if a.agi != b.agi:
			return a.agi > b.agi
		return a.id < b.id
	)
	return out


func unit_at(cell: Vector3i) -> Unit:
	var uid := grid.occupant_at(cell)
	return unit_by_id(uid) if uid != -1 else null


## 移动单位到新位置（唯一入口，保证占格同步）
func relocate_unit(u: Unit, new_anchor: Vector3i, new_facing: int) -> bool:
	if not HexFootprint.can_place(grid, new_anchor, u.footprint(), new_facing, u.id, u.can_crush_rubble()):
		return false
	grid.clear_occupancy(u.id)
	u.anchor = new_anchor
	u.facing = new_facing
	grid.set_occupancy(u.id, u.cells())
	return true


func kill_unit(u: Unit) -> void:
	u.is_alive = false
	u.hp = 0
	grid.clear_occupancy(u.id)
	log_event("unit_died", {"unit": u.id, "name": u.display_name})


# ------------------------------------------------------------------ 日志

func log_event(type: String, data: Dictionary) -> void:
	event_log.append({"t": type, "d": data})


func log_action(a: GameAction) -> void:
	action_log.append(a.to_dict())


## 供表现层每帧调用，取走并清空事件
func drain_events() -> Array:
	var out := event_log.duplicate()
	event_log.clear()
	return out


## 确定性验证用的哈希（纪律 5）
func action_log_hash() -> int:
	return JSON.stringify(action_log).hash()


# ------------------------------------------------------------------ 胜负（§8.10）

func check_victory() -> void:
	if is_over:
		return
	var p := player()
	if p == null or not p.is_alive:
		is_over = true
		player_won = false
		phase = GameEnums.BattlePhase.BATTLE_LOSE
		log_event("battle_ended", {"won": false, "round": round_number})
		return
	match win_condition:
		GameEnums.WinCondition.KILL_ALL:
			if alive_enemies().is_empty():
				is_over = true
				player_won = true
				phase = GameEnums.BattlePhase.EXPLORE
				log_event("battle_ended", {"won": true, "round": round_number})
		_:
			pass


# ------------------------------------------------------------------ 快照（Undo，§13.2）

## Undo 用【快照】而非逆动作 —— 逆动作在有状态/位移/牌堆的系统里必然写错。
## 体积：49 格 + ≤6 单位 + 4 个牌堆 ≈ 几 KB，回合制下零压力。
func snapshot() -> Dictionary:
	var us: Array = []
	for u in units:
		us.append(u.to_dict())
	return {
		"grid": grid.to_dict(),
		"units": us,
		"next_uid": _next_unit_id,
		"player": player_unit_id,
		"phase": int(phase),
		"round": round_number,
		"energy": energy,
		"played": cards_played_this_round,
		"piles": piles.to_dict(),
		"rng_draw": rng.draw_count,
		"rng": rng.save_states(),
		"agg": rule_agg.duplicate(true),
		"over": is_over,
		"won": player_won,
		"action_log_len": action_log.size(),
	}


func restore(s: Dictionary) -> void:
	grid = HexGrid.from_dict(s["grid"])
	units.clear()
	for d in s["units"]:
		units.append(Unit.from_dict(d))
	_next_unit_id = s.get("next_uid", 1)
	player_unit_id = s.get("player", -1)
	phase = s.get("phase", GameEnums.BattlePhase.PLAYER_PHASE)
	round_number = s.get("round", 0)
	energy = s.get("energy", 0)
	cards_played_this_round = s.get("played", 0)
	rng.load_states(s.get("rng", {}))
	rule_agg = (s.get("agg", {}) as Dictionary).duplicate(true)
	is_over = s.get("over", false)
	player_won = s.get("won", false)
	# 动作日志回退到快照点
	var target_len: int = s.get("action_log_len", action_log.size())
	if action_log.size() > target_len:
		action_log = action_log.slice(0, target_len)
	queue.clear()
