extends Node2D
class_name HexBoardView
## 全项目【唯一】接触六边形几何与 TileMap 坐标的表现层文件 —— 见 §4.2 的隔离决策
##
## 对外只暴露：
##   world_pos_of(col,row) / world_pos_of_cube() / hex_points() /
##   cell_at_mouse() / paint_highlight() / clear_highlight() /
##   board_rect() / depth_scale_at()
## 任何 UI / 预览节点都不许自己算六边形坐标。
## 由 tools/check_discipline.gd 的白名单强制。
##
## ════════════════════════════════════════════════════════════════════
## 为什么从 TileMapLayer 改成手绘
## ════════════════════════════════════════════════════════════════════
##
## 背景是有真透视的地铁站台（中间亮区远边宽度约为近边一半）。平的战场叠上去
## 像贴纸。而 TileMapLayer 渲染是**纯仿射**的（Node2D 的 Transform2D 没有
## 透视除法），无法做逐顶点除 w，所以贴不到收敛的地板上。
##
## 代价其实极小：`GreyboxTileSet` 本来就只是"一张白六边形 + 12 个 modulate 色"，
## 我们是把 TileMapLayer 当**纯色六边形渲染器**在用。换成 draw_colored_polygon
## 后画质反而更好（矢量多边形，无重采样），49 格 × 6 顶点毫无性能压力。
##
## 原先的 TerrainLayer / HazardLayer / HighlightLayer 三层（美术文档 §9.2）
## 语义完整保留，只是从"三个节点"变成"_draw() 里的三个绘制批次"，
## 顺序仍是 地形 → 危害 → 高亮。
##
## ⚠️ 布局公式已用 tools/tmp_verify_hexlayout.gd 与 TileMapLayer.map_to_local
##   逐格比对过 49 格，误差 0.000000 px。改这个公式前请重跑该校验 ——
##   偏移写错会重演文档「陷阱 2」：单看一格完全正常，只有相邻关系错位。

## 平面空间的六边形布局（等价于 Godot STACKED + OFFSET_AXIS_HORIZONTAL）
##   x = (map_x + 0.5 + (map_y 为奇数 ? 0.5 : 0)) * TILE_W
##   y = (map_y * 3/4 + 0.5) * TILE_H
## 其中 +0.5 是 tile 中心偏移（map(0,0) 的中心在 (W/2, H/2)），
## 奇数行右移半格 = odd-r。
const ROW_SPACING_RATIO := 0.75

## 网格占用地板的【纵深比例】。1 = 用满整块亮地砖，0.6 = 只用近侧 60%。
##
## 这是削弱透视的正确旋钮：远边沿地板平面朝近边移动，四角始终留在地砖上，
## 所以网格永远贴地，只是收敛变缓。
##
## ⚠️ 不要用"把四边形插值成矩形"的方式削弱透视 —— 那会让四角离开地板平面，
##   网格盖到列车和天花板上（第一版实测踩过，见 GroundProjection 注释）。
##
## 0.78 的依据：地板远边宽度只有近边的 50%，用满时顶行格宽只有底行一半，
## 顶行敌人会小到读不出意图。取 0.78 后收敛比升到约 0.61，远端仍留出一段
## 地板与远景墙面，构图上也更像"站在站台上"而不是"站台被格子铺满"。
const FLOOR_DEPTH_SPAN := 0.78

## 单位尺寸对透视的跟随程度（0 = 完全不缩放，1 = 物理正确）。
## 地面走满透视、角色欠透视 —— 见 GroundProjection.unit_depth_scale 的说明。
const UNIT_DEPTH_INFLUENCE := 0.62

## 地板四边形在【背景纹理归一化坐标】里的位置（顺序：左上 右上 右下 左下）。
##
## 只覆盖中间亮地砖区 —— 左侧列车、右侧闸机/墙自然成为战场边界，
## 既省掉"顶行过小"的可读性问题，也比铺满整幅更合理。
## 数值来自对 Chapter1_BattleScene.png（2048×1152）的实测，可用 F2 校对。
const FLOOR_QUAD_UV := [
	Vector2(0.320, 0.288),   # 左上（远，墙根稍下方，保留远景墙面）
	Vector2(0.720, 0.288),   # 右上（远）
	Vector2(0.946, 0.922),   # 右下（近）
	Vector2(0.145, 0.922),   # 左下（近）
]

## 高亮色与地形色沿用灰盒配色（美术文档 §4.4 的功能色专用原则）
const C := GreyboxTileSet.COLORS
const Alt := GreyboxTileSet.Alt

## 有背景图时各地形的填充不透明度。
##
## ⚠️ 这是"贴地感"的关键，不是美化。灰盒期 FLOOR 是 100% 不透明的 #3A3A40，
##   把背景地砖整片糊住 —— 结果读起来是"一块灰色蜂巢板压在站台上"，
##   而不是"格线画在地砖上"（实测截图确认，透视做对了但观感仍是贴纸）。
##
## 现在背景本身就是 TerrainLayer 的美术（美术文档 §9.2 原本就把地形底图
## 划归美术产出），所以灰盒填充让位，可读性交给格线（R7）。
##
## 但【障碍物必须保持高不透明度】：墙/坑/瓦砾是玩家判断走位合法性的依据，
## 它们不能"融进背景"，否则会误判能不能走过去。
const TERRAIN_ALPHA := {
	Alt.FLOOR: 0.12,        ## 地面：几乎透明，只留一点统一色调压住背景杂色
	Alt.WALL: 0.88,         ## 墙：必须挡眼，是硬边界
	Alt.PIT: 0.90,          ## 坑：致死地形，最高可读性
	Alt.RUBBLE: 0.72,       ## 瓦砾：可被 L 压碎，需明显但不至于像墙
	Alt.EXIT_GATE: 0.65,    ## 出口
}
## 未列出的地形回退值
const TERRAIN_ALPHA_DEFAULT := 0.5

## 格线颜色与宽度。
## 地形填充让位给背景后，**格线成为战场可读性的主要承担者** ——
## 美术文档 R7 要求格线始终可见（最低 15% 不透明度）。
##
## ⚠️ 取 0.30 时远端几乎看不见（实测截图）：透视把远排格线挤在一起，
##   加上背景地砖本身有纹理，低对比度直接输掉。故提到 0.55 并对
##   远端【加粗补偿】（见 _draw 里的 depth 补偿）。
const GRID_LINE_COLOR := Color(0.86, 0.91, 1.0, 0.55)
const GRID_LINE_WIDTH := 1.6

var projection := GroundProjection.new()

## 坐标调试层（F1 切换）—— 便宜且救命
var show_coords := false
## 地板四边形调试叠层（F2 切换）—— 校准 FLOOR_QUAD_UV 用
var show_floor_debug := false

## 当前渲染数据（由 render_grid 填充，纯显示用）
var _terrain: Dictionary = {}    ## Vector2i(col,row) -> Alt
var _hazard: Dictionary = {}     ## Vector2i(col,row) -> Alt
var _highlight: Dictionary = {}  ## Vector2i(col,row) -> Alt

## 地板四边形的屏幕坐标（由 battle_scene 依背景变换算出后注入）
var _floor_quad: Array = []


func _ready() -> void:
	_rebuild_projection()


# ══════════════════════════════════════════════════════ 平面布局

## 平面空间的格心（未投影）。这是几何的唯一来源。
func flat_pos_of(col: int, row: int) -> Vector2:
	var m := HexCoord.offset_to_map(col, row)
	var odd := 0.5 if (m.y & 1) != 0 else 0.0
	return Vector2(
		(float(m.x) + 0.5 + odd) * float(K.TILE_W),
		(float(m.y) * ROW_SPACING_RATIO + 0.5) * float(K.TILE_H))


## 平面空间的六边形顶点（未投影）
func flat_hex_points(col: int, row: int) -> PackedVector2Array:
	var c := flat_pos_of(col, row)
	var pts := PackedVector2Array()
	var rx := float(K.TILE_W) * 0.5
	var ry := float(K.TILE_H) * 0.5
	for i in range(6):
		var ang := deg_to_rad(60.0 * float(i) - 90.0)
		pts.append(c + Vector2(rx * cos(ang), ry * sin(ang)))
	return pts


## 全部 49 格顶点的平面外接框 —— 单应变换的源矩形
func flat_bounds() -> Rect2:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			for p in flat_hex_points(col, row):
				mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
				mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


# ══════════════════════════════════════════════════════ 投影

## 由 battle_scene 注入地板四边形（屏幕坐标，顺序 左上/右上/右下/左下）。
## 传空数组 = 回退平面模式。
func set_floor_quad(quad: Array) -> void:
	_floor_quad = quad.duplicate()
	_rebuild_projection()
	queue_redraw()


func _rebuild_projection() -> void:
	if _floor_quad.size() != 4:
		projection = GroundProjection.new()   # 无效 → project() 原样返回
		return
	# 先沿地板平面收缩纵深，再建单应 —— 四角仍在地砖上
	projection.setup(flat_bounds(),
		GroundProjection.shrink_depth(_floor_quad, FLOOR_DEPTH_SPAN))


## 某格处的地面深度缩放（近 ≈1.0，远 <1.0）。格线宽度、阴影等地面元素用它。
func depth_scale_at(col: int, row: int) -> float:
	return projection.depth_scale(flat_pos_of(col, row))


## 某格处的【单位】深度缩放 —— 弱化版，保住远处角色的可读性
func unit_depth_scale_at(col: int, row: int) -> float:
	return projection.unit_depth_scale(flat_pos_of(col, row), UNIT_DEPTH_INFLUENCE)


# ══════════════════════════════════════════════════════ 对外几何出口

## 格中心的世界坐标（供单位定位、描边、飘字用）
func world_pos_of(col: int, row: int) -> Vector2:
	return projection.project(flat_pos_of(col, row))


func world_pos_of_cube(c: Vector3i) -> Vector2:
	var o := HexCoord.cube_to_offset(c)
	return world_pos_of(o.x, o.y)


## 六边形顶点（用于 footprint 描边）。
## ⚠️ 必须逐个投影平面顶点，不能在投影后的空间里加 rx/ry 偏移 ——
##   那样在透视下会得到错误的形状（上下边不等宽）。
func hex_points(col: int, row: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in flat_hex_points(col, row):
		out.append(projection.project(p))
	return out


## 鼠标所在格（offset 坐标）。返回 Vector2i(-1,-1) 表示界外。
##
## 做法：屏幕 → 逆投影到平面 → 找最近格心 → 再验证点确实落在该格内。
## 六边形网格中"最近格心"就是正确答案（格子即格心的 Voronoi 胞），
## 所以不需要遍历候选做复杂判定；最后的点在多边形内测试只用于剔除界外点击。
func cell_at_mouse() -> Vector2i:
	var flat := projection.unproject(to_local(get_global_mouse_position()))

	var best := Vector2i(-1, -1)
	var best_d := INF
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var d := flat.distance_squared_to(flat_pos_of(col, row))
			if d < best_d:
				best_d = d
				best = Vector2i(col, row)
	if best.x < 0:
		return Vector2i(-1, -1)

	# 界外剔除：点必须真的在该格的平面六边形内
	if not Geometry2D.is_point_in_polygon(flat, flat_hex_points(best.x, best.y)):
		return Vector2i(-1, -1)
	return best


## 战场整体的世界矩形（供相机居中）。取投影后四角的 AABB。
func board_rect() -> Rect2:
	if projection.is_valid():
		return projection.projected_bounds()
	return flat_bounds()


# ══════════════════════════════════════════════════════ 渲染数据

## 按 HexGrid 重建地形与危害数据
func render_grid(grid: HexGrid) -> void:
	_terrain.clear()
	_hazard.clear()
	for c in grid.all_cells():
		var o := HexCoord.cube_to_offset(c)
		var key := Vector2i(o.x, o.y)
		_terrain[key] = GreyboxTileSet.alt_for_terrain(grid.terrain_at(c))
		var hz := GreyboxTileSet.alt_for_hazard(grid.hazard_at(c))
		if hz >= 0:
			_hazard[key] = hz
	queue_redraw()


func paint_highlight(cells: Array, alt: int) -> void:
	for c in cells:
		var o := HexCoord.cube_to_offset(c as Vector3i)
		_highlight[Vector2i(o.x, o.y)] = alt
	queue_redraw()


func clear_highlight() -> void:
	_highlight.clear()
	queue_redraw()


# ══════════════════════════════════════════════════════ 绘制
#
# 图层顺序对齐美术文档 §9.2：Terrain → Hazard → Highlight。
# 全部走投影后的多边形，于是格子真正"躺"在背景地板上。

func _draw() -> void:
	# 有背景图时地形填充压到近乎透明，让地砖透出来；无背景则保持灰盒不透明
	var over_bg := _floor_quad.size() == 4

	# ── 1. 地形
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var key := Vector2i(col, row)
			if not _terrain.has(key):
				continue
			var alt: int = _terrain[key]
			var base: Color = C.get(alt, Color.WHITE)
			var poly := hex_points(col, row)
			if over_bg:
				var a: float = TERRAIN_ALPHA.get(alt, TERRAIN_ALPHA_DEFAULT)
				draw_colored_polygon(poly, Color(base.r, base.g, base.b, a))
			else:
				draw_colored_polygon(poly, base)
			# 格线（美术文档 R7：始终可见，最低 15% 不透明度）
			#
			# ⚠️ 远端【不能】按深度缩放线宽 —— 那会让远排格线细到消失。
			#   透视已经把远排挤密了，线宽必须保持屏幕空间常量（≥1.4px），
			#   否则 R7 在最需要它的地方失效。这是有意的"欠透视"。
			draw_polyline(_closed(poly), GRID_LINE_COLOR,
				maxf(1.4, GRID_LINE_WIDTH), true)

	# ── 2. 危害层
	for key in _sorted_keys(_hazard):
		draw_colored_polygon(hex_points(key.x, key.y),
			C.get(_hazard[key], Color.WHITE))

	# ── 3. 高亮层（半透明填充 + 描边，无花纹 —— 美术文档 §9.2）
	for key in _sorted_keys(_highlight):
		var col_v: Color = C.get(_highlight[key], Color.WHITE)
		var poly := hex_points(key.x, key.y)
		draw_colored_polygon(poly, col_v)
		draw_polyline(_closed(poly), Color(col_v.r, col_v.g, col_v.b, 0.9), 2.0, true)

	# ── 4. 调试叠层
	if show_floor_debug:
		_draw_floor_debug()
	if show_coords:
		_draw_coords()


## 确定性遍历顺序（纪律 5：不依赖 Dictionary 遍历顺序）
func _sorted_keys(d: Dictionary) -> Array:
	var keys: Array = d.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return keys


static func _closed(poly: PackedVector2Array) -> PackedVector2Array:
	var out := poly.duplicate()
	if out.size() > 0:
		out.append(out[0])
	return out


func _draw_coords() -> void:
	var f := ThemeDB.fallback_font
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var p := world_pos_of(col, row)
			# 字号按深度缩放，远处标签不至于糊成一团
			var fs := int(round(18.0 * depth_scale_at(col, row)))
			draw_string(f, p + Vector2(-22.0 * depth_scale_at(col, row), 5),
				"(%d,%d)" % [col, row],
				HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(fs, 9), Color(1, 1, 1, 0.65))


## F2：画出地板四边形（黄=原始地板 UV，橙=收缩后的实际网格四角）
## 与投影后的战场外框，用于校准 FLOOR_QUAD_UV / FLOOR_DEPTH_SPAN
func _draw_floor_debug() -> void:
	var f := ThemeDB.fallback_font
	if _floor_quad.size() == 4:
		# 原始地板 UV（黄）
		var q := PackedVector2Array()
		for p in _floor_quad:
			q.append(p as Vector2)
		draw_polyline(_closed(q), Color(1.0, 0.85, 0.2, 0.9), 3.0, true)
		var names := ["TL", "TR", "BR", "BL"]
		for i in range(4):
			draw_circle(q[i], 7.0, Color(1.0, 0.85, 0.2))
			draw_string(f, q[i] + Vector2(10, -6), names[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1.0, 0.85, 0.2))

		# 收缩纵深后的实际网格四角（橙）
		var shrunk := GroundProjection.shrink_depth(_floor_quad, FLOOR_DEPTH_SPAN)
		var q2 := PackedVector2Array()
		for p in shrunk:
			q2.append(p as Vector2)
		draw_polyline(_closed(q2), Color(1.0, 0.45, 0.1, 0.95), 3.0, true)

		draw_string(f, q[3] + Vector2(0, 26),
			"span=%.2f  unit_influence=%.2f" % [FLOOR_DEPTH_SPAN, UNIT_DEPTH_INFLUENCE],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1.0, 0.6, 0.2))
	var r := board_rect()
	draw_rect(r, Color(0.3, 1.0, 0.9, 0.8), false, 2.0)


func toggle_coords() -> void:
	show_coords = not show_coords
	queue_redraw()


func toggle_floor_debug() -> void:
	show_floor_debug = not show_floor_debug
	queue_redraw()
