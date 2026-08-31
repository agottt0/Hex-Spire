class_name TargetSpec
extends Resource
## 目标规格 —— §15.5

@export var shape: GameEnums.TargetShape = GameEnums.TargetShape.SINGLE
@export var range_min: int = 0
@export var range_max: int = 1
## LINE/CONE/BURST 的尺寸
@export var area_size: int = 0
@export var requires_line_of_sight: bool = true
@export var can_target_empty_cell: bool = false
## 允许的队伍（空 = 不限）
@export var valid_teams: Array[int] = []
## 允许的体型（空 = 不限）
@export var valid_size_classes: Array[int] = []


static func make(
	p_shape: GameEnums.TargetShape,
	p_rmin: int = 0,
	p_rmax: int = 1,
	p_area: int = 0,
	p_los: bool = true
) -> TargetSpec:
	var t := TargetSpec.new()
	t.shape = p_shape
	t.range_min = p_rmin
	t.range_max = p_rmax
	t.area_size = p_area
	t.requires_line_of_sight = p_los
	# ⚠️ TILE 形状的语义就是"指向一个格子"（移动/传送/地形改造），
	#    必须允许空格，否则移动卡的合法目标恒为空 —— 实测踩过：
	#    玩家永远走不动，双方对着空转直到超时。
	t.can_target_empty_cell = (p_shape == GameEnums.TargetShape.TILE)
	return t


static func self_target() -> TargetSpec:
	return make(GameEnums.TargetShape.SELF, 0, 0, 0, false)
