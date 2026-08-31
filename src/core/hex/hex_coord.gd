class_name HexCoord
## 六边形坐标系的【唯一转换出口】—— 策划案 §8.1
##
## 禁止在任何其他文件手写坐标转换。
##
## 两套坐标：
##   对外（策划/存档/UI）：offset (col, row)，odd-r，**1-indexed，原点在左下角**
##   对内（算法/距离/旋转/footprint）：cube Vector3i(x,y,z)，恒满足 x+y+z == 0
##
## ⚠️ 陷阱 H1：`DIRS[facing]` 不是朝向向量！
##   rotate() 把 DIRS[i] 映射到 DIRS[(i-1) mod 6]（索引递减），
##   所以 facing=2 的 footprint 朝上，但 DIRS[2] 却指向 row 减小的方向（朝下）。
##   取朝向向量必须用 facing_dir()。见该函数注释。
##
## 本文件的结论均经过实测验算（7×7 全 49 格 roundtrip、旋转闭合、
## §8.2.4 出生表逐格比对），见 tests/test_hex_coord.gd。

const COLS := 7
const ROWS := 7

## 业务 row 1 在【下】，而 Godot TileMap 的 y 向【下】增长，需要翻转。
## ⚠️ 这个常数【必须是偶数】：
##   `K - row` 与 `row` 同奇偶 ⟺ K 为偶数。
##   若取奇数（例如 ROWS=7），row 的奇偶性会翻转，odd-r 的"奇数行右移"
##   会渲染成"偶数行右移" —— 整个网格被剪切错位，且只有相邻关系错、
##   单看一格完全正常，极难发现。
const MAP_Y_FLIP := 8

## 6 个方向向量。索引【不是】朝向，取朝向请用 facing_dir()。
const DIRS: Array[Vector3i] = [
	Vector3i(1, -1, 0),
	Vector3i(1, 0, -1),
	Vector3i(0, 1, -1),
	Vector3i(-1, 1, 0),
	Vector3i(-1, 0, 1),
	Vector3i(0, -1, 1),
]


# ---------------------------------------------------------------- offset ↔ cube

## odd-r 偏移 (1-indexed, 左下原点) → 立方坐标
static func offset_to_cube(col: int, row: int) -> Vector3i:
	var c := col - 1
	var r := row - 1
	# 被除数恒为偶数，故截断除法与 floor 除法等价，负数区间也安全
	var x := c - (r - (r & 1)) / 2
	var z := r
	return Vector3i(x, -x - z, z)


static func cube_to_offset(cube: Vector3i) -> Vector2i:
	var col := cube.x + (cube.z - (cube.z & 1)) / 2 + 1
	var row := cube.z + 1
	return Vector2i(col, row)


static func offset_to_cube_v(offset: Vector2i) -> Vector3i:
	return offset_to_cube(offset.x, offset.y)


# ---------------------------------------------------------------- 度量

static func distance(a: Vector3i, b: Vector3i) -> int:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi(a.z - b.z)))


static func neighbor(cube: Vector3i, dir_index: int) -> Vector3i:
	return cube + DIRS[posmod(dir_index, 6)]


static func neighbors(cube: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for d in DIRS:
		out.append(cube + d)
	return out


static func in_bounds(cube: Vector3i) -> bool:
	var o := cube_to_offset(cube)
	return o.x >= 1 and o.x <= COLS and o.y >= 1 and o.y <= ROWS


# ---------------------------------------------------------------- 旋转与朝向

## 绕原点旋转 60° × steps。
##
## 公式取自策划案 §8.1 原文，【不要改】—— 已用 §8.2.4 的出生表验证：
##   facing=2 时 M 体型占 (4,1)(3,2)(4,2)，row 递增 = 朝上 ✓
##   facing=2 时 L 体型占 (4,1)(3,2)(4,2)(3,3)(4,3)(5,3)，全在 7×7 内 ✓
## 曾考虑的"修正"公式 (-y,-z,-x) 会把出生点算到 row 0 / -1，直接出界。
##
## 注意：本公式使 DIRS 的索引【递减】（DIRS[0] → DIRS[5] → DIRS[4] ...）。
## 策划案原注释写"顺时针"，但在 odd-r + row 向上的约定下它表现为索引递减。
## 这不影响正确性（旋转自洽、footprint 不重叠），但意味着不能拿 facing
## 直接去索引 DIRS —— 这就是 facing_dir() 存在的原因。
static func rotate(cube: Vector3i, steps: int) -> Vector3i:
	var v := cube
	for _i in range(posmod(steps, 6)):
		v = Vector3i(-v.z, -v.x, -v.y)
	return v


## 朝向 facing (0-5) 对应的【单位方向向量】。
##
## ⚠️ 这是 facing → 方向 的唯一出口。禁止写 DIRS[unit.facing]。
##   由 tests/test_architecture_discipline.gd 的 grep 规则强制。
##
## 之所以是 posmod(-facing, 6)：rotate() 让索引递减，而 footprint 是用
## rotate(offset, facing) 展开的，所以朝向向量必须用同样的递减方向取。
## 已验证 6 个朝向下 facing_dir 均落在 footprint 的尖端侧。
static func facing_dir(facing: int) -> Vector3i:
	return DIRS[posmod(-facing, 6)]


## 朝向 facing 的【正后方】方向索引。实测对 6 个朝向均成立。
static func rear_dir_index(facing: int) -> int:
	return posmod(3 - facing, 6)


## 背击后弧的方向向量集合。
## §8.2.3 只写了"背面 2 个方向"未指明是哪两个 —— 偏移量放在 K 里，
## 试玩后可一键调整（含改成 3 方向对称后弧）。见 constants.gd。
static func backstab_dirs(facing: int) -> Array[Vector3i]:
	var b := rear_dir_index(facing)
	var out: Array[Vector3i] = []
	for off in K.BACKSTAB_REAR_OFFSETS:
		out.append(DIRS[posmod(b + off, 6)])
	return out


# ---------------------------------------------------- Godot TileMap 映射（隔离层）

## offset (col,row) → Godot TileMapLayer 的 map 坐标。
## ⚠️ 只允许 src/scenes/battle/hex_board_view.gd 调用（纪律测试强制）。
static func offset_to_map(col: int, row: int) -> Vector2i:
	return Vector2i(col - 1, MAP_Y_FLIP - row)


static func map_to_offset(m: Vector2i) -> Vector2i:
	return Vector2i(m.x + 1, MAP_Y_FLIP - m.y)


static func cube_to_map(cube: Vector3i) -> Vector2i:
	var o := cube_to_offset(cube)
	return offset_to_map(o.x, o.y)


static func map_to_cube(m: Vector2i) -> Vector3i:
	var o := map_to_offset(m)
	return offset_to_cube(o.x, o.y)
