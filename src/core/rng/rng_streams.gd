class_name RngStreams
extends RefCounted
## 注入式 RNG —— 架构纪律 1（§12.1）
##
## ⚠️ 这是 RefCounted 而非 autoload，因为 src/core/ 不许引用 Node。
##   autoload RNGService 只是它的持有者，通过构造参数【注入】进 BattleState。
##   battle_sim 与单测直接 new 一个，不依赖任何 autoload。
##
## 单一主 seed 派生 5 条独立子流，各流状态可存入 RunState.rng_states，
## 从而支持：种子分享、录像回放、bug 精确复现、可重复的自动化测试。
##
## ⚠️ 禁止使用 Array.shuffle() / pick_random() —— 它们用全局 RNG，
##   会破坏确定性且在 10 万场模拟里"每次都随机成功"，极难发现。
##   洗牌请用本类的 shuffle()。

const STREAM_NAMES := ["map", "loot", "combat", "deck", "event"]

var map: RandomNumberGenerator
var loot: RandomNumberGenerator
var combat: RandomNumberGenerator
var deck: RandomNumberGenerator
var event: RandomNumberGenerator

var master_seed: int = 0

## 任何流被消费的累计次数。Undo 用它判断"是否已产生随机结果"（撤销屏障）。
var draw_count: int = 0


func _init(p_master_seed: int = 0) -> void:
	master_seed = p_master_seed
	var streams: Array[RandomNumberGenerator] = []
	for i in range(STREAM_NAMES.size()):
		var r := RandomNumberGenerator.new()
		r.seed = _derive_seed(p_master_seed, i)
		streams.append(r)
	map = streams[0]
	loot = streams[1]
	combat = streams[2]
	deck = streams[3]
	event = streams[4]


## splitmix64 的三个魔数。
## ⚠️ GDScript 的 int 是【有符号】64 位，字面量写 0x9E37... 会报
##   "value is too large"。这里用等价的负数补码字面量表示同一位模式。
##   0x9E3779B97F4A7C15 == -7046029254386353131
##   0xBF58476D1CE4E5B9 == -4658895280553007687
##   0x94D049BB133111EB == -7723592293110705877
const _GOLDEN := -7046029254386353131
const _MIX_A := -4658895280553007687
const _MIX_B := -7723592293110705877
const _MASK63 := 0x7FFFFFFFFFFFFFFF

## 从主 seed 派生子 seed。必须是纯函数（同 master_seed 必得同结果）。
static func _derive_seed(master: int, stream_index: int) -> int:
	# splitmix64 风格混合，避免相邻 seed 产生相关序列。
	# 乘法溢出在 GDScript 里是环绕的（等价于 mod 2^64），符合算法预期。
	var x := (master + (stream_index + 1) * _GOLDEN) & _MASK63
	x = ((x ^ (x >> 30)) * _MIX_A) & _MASK63
	x = ((x ^ (x >> 27)) * _MIX_B) & _MASK63
	return (x ^ (x >> 31)) & _MASK63


## Fisher-Yates 洗牌。就地修改，使用指定流。
## 这是全项目【唯一】允许的洗牌实现。
func shuffle(arr: Array, stream: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := stream.randi_range(0, i)
		draw_count += 1
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## 掷一次 [0,1) 浮点，并计入 draw_count
func randf_from(stream: RandomNumberGenerator) -> float:
	draw_count += 1
	return stream.randf()


## 掷一次 [from,to] 整数，并计入 draw_count
func randi_from(stream: RandomNumberGenerator, from: int, to: int) -> int:
	draw_count += 1
	return stream.randi_range(from, to)


## 概率判定：p ∈ [0,1]
func chance(stream: RandomNumberGenerator, p: float) -> bool:
	return randf_from(stream) < p


# ------------------------------------------------------------------ 存档

func save_states() -> Dictionary:
	return {
		"master_seed": master_seed,
		"draw_count": draw_count,
		"map": {"seed": map.seed, "state": map.state},
		"loot": {"seed": loot.seed, "state": loot.state},
		"combat": {"seed": combat.seed, "state": combat.state},
		"deck": {"seed": deck.seed, "state": deck.state},
		"event": {"seed": event.seed, "state": event.state},
	}


func load_states(d: Dictionary) -> void:
	master_seed = d.get("master_seed", 0)
	draw_count = d.get("draw_count", 0)
	for name in STREAM_NAMES:
		if not d.has(name):
			continue
		var sd: Dictionary = d[name]
		var r: RandomNumberGenerator = get(name)
		r.seed = sd.get("seed", 0)
		r.state = sd.get("state", 0)
