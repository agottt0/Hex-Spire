class_name Actions
## GameAction 的命名构造器集合。
##
## 存在理由：GameAction 用扁平 Dictionary 换取了可序列化性，代价是字段没有
## 静态类型。这里把每种动作的构造集中起来，让调用方仍然有"函数签名"级别的
## 约束，也让 data 的键名只在一处定义。
##
## ⚠️ 新增一种 action type 必须同时：
##   1. 在这里加构造器
##   2. 在 ActionResolver 注册处理器
##   否则 tools/data_linter.gd 会报"有构造无处理器"。

const DAMAGE := &"DAMAGE"
const GAIN_BLOCK := &"GAIN_BLOCK"
const HEAL := &"HEAL"
const MOVE := &"MOVE"
const ROTATE := &"ROTATE"
const KNOCKBACK := &"KNOCKBACK"
const PULL := &"PULL"
const TRAMPLE := &"TRAMPLE"
const APPLY_STATUS := &"APPLY_STATUS"
const REMOVE_STATUS := &"REMOVE_STATUS"
const DRAW := &"DRAW"
const DISCARD := &"DISCARD"
const EXHAUST := &"EXHAUST"
const RESHUFFLE := &"RESHUFFLE"
const GAIN_ENERGY := &"GAIN_ENERGY"
const SPEND_ENERGY := &"SPEND_ENERGY"
const MODIFY_STAT := &"MODIFY_STAT"
const DIE := &"DIE"
const HAZARD_TICK := &"HAZARD_TICK"


## 伤害。packet 由 DamageCalculator 产出，含最终 int 值与元信息。
static func damage(source_id: int, target_id: int, packet: Dictionary, tag: String = "") -> GameAction:
	var a := GameAction.new(DAMAGE, {"src": source_id, "tgt": target_id, "packet": packet})
	a.source_tag = tag
	return a


static func gain_block(target_id: int, amount: int, tag: String = "") -> GameAction:
	var a := GameAction.new(GAIN_BLOCK, {"tgt": target_id, "amount": amount})
	a.source_tag = tag
	return a


static func heal(target_id: int, amount: int, tag: String = "") -> GameAction:
	var a := GameAction.new(HEAL, {"tgt": target_id, "amount": amount})
	a.source_tag = tag
	return a


## 移动。path 是 offset 坐标数组（可序列化），最后一项是落点。
## facing 为 -1 表示不改变朝向。
static func move(unit_id: int, path_offsets: Array, new_facing: int = -1, tag: String = "") -> GameAction:
	var a := GameAction.new(MOVE, {"unit": unit_id, "path": path_offsets, "facing": new_facing})
	a.source_tag = tag
	return a


static func rotate_unit(unit_id: int, new_facing: int, tag: String = "") -> GameAction:
	var a := GameAction.new(ROTATE, {"unit": unit_id, "facing": new_facing})
	a.source_tag = tag
	return a


## 击退。dir_index 是 HexCoord.DIRS 的索引，distance 是格数。
static func knockback(unit_id: int, dir_index: int, distance: int, tag: String = "") -> GameAction:
	var a := GameAction.new(KNOCKBACK, {"unit": unit_id, "dir": dir_index, "dist": distance})
	a.source_tag = tag
	return a


static func pull(unit_id: int, dir_index: int, distance: int, tag: String = "") -> GameAction:
	var a := GameAction.new(PULL, {"unit": unit_id, "dir": dir_index, "dist": distance})
	a.source_tag = tag
	return a


static func apply_status(target_id: int, status_id: String, stacks: int, tag: String = "") -> GameAction:
	var a := GameAction.new(APPLY_STATUS, {"tgt": target_id, "status": status_id, "stacks": stacks})
	a.source_tag = tag
	return a


static func draw(count: int, tag: String = "") -> GameAction:
	var a := GameAction.new(DRAW, {"count": count})
	a.source_tag = tag
	return a


static func discard_card(card_uid: int, tag: String = "") -> GameAction:
	var a := GameAction.new(DISCARD, {"uid": card_uid})
	a.source_tag = tag
	return a


static func exhaust_card(card_uid: int, tag: String = "") -> GameAction:
	var a := GameAction.new(EXHAUST, {"uid": card_uid})
	a.source_tag = tag
	return a


static func reshuffle(tag: String = "") -> GameAction:
	var a := GameAction.new(RESHUFFLE, {})
	a.source_tag = tag
	return a


static func gain_energy(amount: int, tag: String = "") -> GameAction:
	var a := GameAction.new(GAIN_ENERGY, {"amount": amount})
	a.source_tag = tag
	return a


static func spend_energy(amount: int, tag: String = "") -> GameAction:
	var a := GameAction.new(SPEND_ENERGY, {"amount": amount})
	a.source_tag = tag
	return a


static func modify_stat(unit_id: int, stat: String, delta: int, tag: String = "") -> GameAction:
	var a := GameAction.new(MODIFY_STAT, {"unit": unit_id, "stat": stat, "delta": delta})
	a.source_tag = tag
	return a


static func die(unit_id: int, tag: String = "") -> GameAction:
	var a := GameAction.new(DIE, {"unit": unit_id})
	a.source_tag = tag
	return a


static func hazard_tick(unit_id: int, hazard: int, cell_count: int, tag: String = "") -> GameAction:
	## ⚠️ cell_count：大体型同时站多个 hazard 时【每格各结算一次】
	##    （§8.2.2 机制点 7 —— 这是大体型的真实代价）
	var a := GameAction.new(HAZARD_TICK, {"unit": unit_id, "hazard": hazard, "cells": cell_count})
	a.source_tag = tag
	return a


## 全部已定义的 action type，供 linter 校验处理器覆盖率
static func all_types() -> Array[StringName]:
	return [
		DAMAGE, GAIN_BLOCK, HEAL, MOVE, ROTATE, KNOCKBACK, PULL, TRAMPLE,
		APPLY_STATUS, REMOVE_STATUS, DRAW, DISCARD, EXHAUST, RESHUFFLE,
		GAIN_ENERGY, SPEND_ENERGY, MODIFY_STAT, DIE, HAZARD_TICK,
	]
