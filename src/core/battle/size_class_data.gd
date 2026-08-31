class_name SizeClassData
extends Resource
## 体型定义 —— D8 / 策划案 §15.2
##
## footprint 是【相对锚点的立方坐标偏移】，配合 facing 用 HexCoord.rotate 展开。
## 三种基准体型都是"六边形三角形"，所以旋转/碰撞代码完全共用（§8.2.1）。

@export var id: GameEnums.SizeClass = GameEnums.SizeClass.S
@export var cell_count: int = 1

## facing=0 时的相对偏移。§8.2.1 的原文数据：
##   S: [(0,0,0)]
##   M: [(0,0,0), (1,-1,0), (1,0,-1)]                                边长2三角
##   L: [(0,0,0), (1,-1,0), (1,0,-1), (2,-2,0), (2,-1,-1), (2,0,-2)] 边长3三角
@export var footprint: Array[Vector3i] = [Vector3i.ZERO]

## 位移抗性：S=0, M=1, L=999（完全免疫）。§8.2.2 机制点 4
@export var default_knockback_resist: int = 0

## 转向成本：S=0, M=0, L=1。§8.2.2 机制点 5
@export var default_rotate_cost: int = 0

## 可碾压比自己小的单位。§8.2.2 机制点 6
@export var can_trample_below: bool = false

## 可压碎 RUBBLE。§8.2.2 机制点 7
@export var can_crush_rubble: bool = false

## 死亡掉落散布半径。§8.2.2 机制点 8
@export var loot_scatter_radius: int = 0


## 三种基准体型的内置构造（避免每处都手写 footprint 数据）
static func make(size: GameEnums.SizeClass) -> SizeClassData:
	var d := SizeClassData.new()
	d.id = size
	match size:
		GameEnums.SizeClass.S:
			d.cell_count = 1
			d.footprint = [Vector3i(0, 0, 0)]
			d.default_knockback_resist = 0
			d.default_rotate_cost = 0
			d.can_trample_below = false
			d.can_crush_rubble = false
			d.loot_scatter_radius = 0
		GameEnums.SizeClass.M:
			d.cell_count = 3
			d.footprint = [Vector3i(0, 0, 0), Vector3i(1, -1, 0), Vector3i(1, 0, -1)]
			d.default_knockback_resist = 1
			d.default_rotate_cost = 0
			d.can_trample_below = true
			d.can_crush_rubble = false
			d.loot_scatter_radius = 1
		GameEnums.SizeClass.L:
			d.cell_count = 6
			d.footprint = [
				Vector3i(0, 0, 0), Vector3i(1, -1, 0), Vector3i(1, 0, -1),
				Vector3i(2, -2, 0), Vector3i(2, -1, -1), Vector3i(2, 0, -2),
			]
			d.default_knockback_resist = 999
			d.default_rotate_cost = 1
			d.can_trample_below = true
			d.can_crush_rubble = true
			d.loot_scatter_radius = 2
	return d
