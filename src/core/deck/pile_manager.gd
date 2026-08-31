class_name PileManager
extends RefCounted
## D2：抽牌堆 / 手牌 / 弃牌堆 / 消耗区 —— §7.4
##
## ⚠️ 三个容易写错、策划案明确规定的点：
##   1. 手牌达上限时【停止抽牌，多余的牌不抽出、留在抽牌堆】（§7.4.2 原文）
##      —— 不是"抽出来然后丢掉"
##   2. 抽牌堆与弃牌堆【都空】时停止抽牌，【不报错】（§7.4.2 原文）
##   3. 洗回必须触发 ON_DECK_RESHUFFLED —— §7.4.3 说这是 D2+D3 的独有设计空间，
##      小卡组下每 2–4 回合就洗一次，是符文组合的高频钩子
##
## 不变量（每次操作后都应成立，测试会断言）：
##   draw.size() + hand.size() + discard.size() + exhaust.size() == 总卡数
##
## ⚠️ 洗牌只用 RngStreams.shuffle(arr, rng.deck)，禁用 Array.shuffle()（纪律1）

var draw_pile: Array[CardInstance] = []
var hand: Array[CardInstance] = []
var discard_pile: Array[CardInstance] = []
var exhaust_pile: Array[CardInstance] = []

## 本场战斗的全部卡实例（用于不变量校验与战斗结束归还）
var _all_cards: Array[CardInstance] = []

## 洗回次数（供 battle_sim 统计 D2 节奏，验证 §7.4.4 的"每 2–4 回合洗一次"）
var reshuffle_count: int = 0


## 战斗开始：卡组 → 洗混 → 抽牌堆（§7.4.2 步骤 1）
##
## capacity: 由 RuleBook.deck_capacity() 给出。若卡组超容量，只取前 capacity 张
##   （《薄纸卡组》符文 DECK_CAPACITY -3 的消费点在这里）。
##   ⚠️ 按卡组【固定顺序】截取而非随机，保证确定性。
func build_from_deck(deck: Array, rng: RngStreams, capacity: int = -1) -> void:
	draw_pile.clear()
	hand.clear()
	discard_pile.clear()
	exhaust_pile.clear()
	_all_cards.clear()
	reshuffle_count = 0

	var source: Array = deck
	if capacity >= 0 and deck.size() > capacity:
		source = deck.slice(0, capacity)

	for c in source:
		draw_pile.append(c)
		_all_cards.append(c)

	rng.shuffle(draw_pile, rng.deck)


## 抽 n 张。返回实际抽到的卡（可能少于 n）。
##
## events: 输出参数，追加纯数据事件（纪律 3：core 不 emit 信号）
func draw(n: int, hand_limit: int, rng: RngStreams, events: Array) -> Array[CardInstance]:
	var drawn: Array[CardInstance] = []
	for _i in range(n):
		# 规则 1：手牌已满 → 停止，多余的牌留在抽牌堆
		if hand.size() >= hand_limit:
			events.append({"t": "hand_full", "d": {"limit": hand_limit}})
			break

		if draw_pile.is_empty():
			# 规则 2：两堆皆空 → 停止，不报错
			if discard_pile.is_empty():
				events.append({"t": "piles_empty", "d": {}})
				break
			_reshuffle(rng, events)

		if draw_pile.is_empty():
			break

		var card: CardInstance = draw_pile.pop_back()
		hand.append(card)
		drawn.append(card)
		events.append({"t": "card_drawn", "d": {"uid": card.uid, "id": card.card_id()}})
	return drawn


## 弃牌堆洗混成新抽牌堆（§7.4.2）。触发 ON_DECK_RESHUFFLED。
func _reshuffle(rng: RngStreams, events: Array) -> void:
	for c in discard_pile:
		draw_pile.append(c)
	discard_pile.clear()
	rng.shuffle(draw_pile, rng.deck)
	reshuffle_count += 1
	events.append({"t": "deck_reshuffled", "d": {"count": draw_pile.size(), "times": reshuffle_count}})


## 打出一张卡后的归宿（§7.4.2 步骤 4）
func resolve_played_card(card: CardInstance, exhaust: bool, events: Array) -> void:
	hand.erase(card)
	if exhaust:
		exhaust_pile.append(card)
		events.append({"t": "card_exhausted", "d": {"uid": card.uid, "id": card.card_id()}})
	else:
		discard_pile.append(card)


## 回合结束弃掉全部手牌（§7.4.2）。每张触发 ON_CARD_DISCARDED。
func discard_hand(events: Array) -> int:
	var n := hand.size()
	for c in hand:
		discard_pile.append(c)
		events.append({"t": "card_discarded", "d": {"uid": c.uid, "id": c.card_id()}})
	hand.clear()
	return n


func discard_one(card: CardInstance, events: Array) -> void:
	if hand.has(card):
		hand.erase(card)
		discard_pile.append(card)
		events.append({"t": "card_discarded", "d": {"uid": card.uid, "id": card.card_id()}})


## 战斗结束：四区全部归还（§7.4.2）
func return_all_to_deck() -> Array[CardInstance]:
	var out: Array[CardInstance] = []
	for c in _all_cards:
		c.temp_cost_delta = 0
		out.append(c)
	draw_pile.clear()
	hand.clear()
	discard_pile.clear()
	exhaust_pile.clear()
	return out


# ------------------------------------------------------------------ 查询

func total_cards() -> int:
	return _all_cards.size()


## 不变量校验（测试与 battle_sim 每步都调）
func invariant_holds() -> bool:
	return draw_pile.size() + hand.size() + discard_pile.size() + exhaust_pile.size() == _all_cards.size()


func find_in_hand(uid: int) -> CardInstance:
	for c in hand:
		if c.uid == uid:
			return c
	return null


## 抽牌堆内容（乱序显示 —— §7.4.1：内容可查看，顺序不可见）
## ⚠️ 返回按 card_id 排序的副本，避免 UI 泄露真实抽牌顺序
func draw_pile_contents_sorted() -> Array[CardInstance]:
	var out: Array[CardInstance] = draw_pile.duplicate()
	out.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		if a.card_id() != b.card_id():
			return a.card_id() < b.card_id()
		return a.uid < b.uid
	)
	return out


func to_dict() -> Dictionary:
	return {
		"draw": _uids(draw_pile),
		"hand": _uids(hand),
		"discard": _uids(discard_pile),
		"exhaust": _uids(exhaust_pile),
		"reshuffles": reshuffle_count,
	}


func _uids(arr: Array) -> Array:
	var out: Array = []
	for c in arr:
		out.append(c.uid)
	return out
