extends Node2D
class_name HexBoardView
## 全项目【唯一】接触 TileMapLayer 的文件 —— 见 §4.2 的隔离决策
##
## 对外只暴露：
##   world_pos_of(col,row) / cell_at_mouse() / paint_highlight() / clear_highlight()
## 任何 UI / 预览节点都不许自己调 local_to_map。
## 由 tools/check_discipline.gd 的白名单强制。

var terrain_layer: TileMapLayer
var hazard_layer: TileMapLayer
var highlight_layer: TileMapLayer
var _tileset: TileSet

## 坐标调试层（F1 切换）—— 便宜且救命
var show_coords := false


func _ready() -> void:
	_tileset = GreyboxTileSet.build()
	terrain_layer = _make_layer("TerrainLayer", 0)
	hazard_layer = _make_layer("HazardLayer", 1)
	highlight_layer = _make_layer("HighlightLayer", 2)


func _make_layer(lname: String, z: int) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.name = lname
	l.tile_set = _tileset
	l.z_index = z
	add_child(l)
	return l


## 按 HexGrid 重绘地形与危害层
func render_grid(grid: HexGrid) -> void:
	terrain_layer.clear()
	hazard_layer.clear()
	for c in grid.all_cells():
		var o := HexCoord.cube_to_offset(c)
		var m := HexCoord.offset_to_map(o.x, o.y)
		var alt := GreyboxTileSet.alt_for_terrain(grid.terrain_at(c))
		terrain_layer.set_cell(m, 0, Vector2i.ZERO, alt)
		var hz := GreyboxTileSet.alt_for_hazard(grid.hazard_at(c))
		if hz >= 0:
			hazard_layer.set_cell(m, 0, Vector2i.ZERO, hz)
	queue_redraw()


## 高亮层整层重填（不每帧重建 —— §14.5）
func paint_highlight(cells: Array, alt: int) -> void:
	for c in cells:
		var cube: Vector3i = c
		var o := HexCoord.cube_to_offset(cube)
		highlight_layer.set_cell(HexCoord.offset_to_map(o.x, o.y), 0, Vector2i.ZERO, alt)


func clear_highlight() -> void:
	highlight_layer.clear()


## 格中心的世界坐标（供单位定位、描边、飘字用）
func world_pos_of(col: int, row: int) -> Vector2:
	var m := HexCoord.offset_to_map(col, row)
	return terrain_layer.map_to_local(m)


func world_pos_of_cube(c: Vector3i) -> Vector2:
	var o := HexCoord.cube_to_offset(c)
	return world_pos_of(o.x, o.y)


## 鼠标所在格（offset 坐标）。返回 Vector2i(-1,-1) 表示界外。
func cell_at_mouse() -> Vector2i:
	var local := terrain_layer.to_local(get_global_mouse_position())
	var m := terrain_layer.local_to_map(local)
	var o := HexCoord.map_to_offset(m)
	if o.x < 1 or o.x > HexCoord.COLS or o.y < 1 or o.y > HexCoord.ROWS:
		return Vector2i(-1, -1)
	return o


## 战场整体的世界矩形（供相机居中）
func board_rect() -> Rect2:
	var a := world_pos_of(1, 1)
	var b := world_pos_of(HexCoord.COLS, HexCoord.ROWS)
	var mn := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var mx := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	# 四角都取一遍（六边形错位会让极值出现在其他角）
	for cell in [[1, HexCoord.ROWS], [HexCoord.COLS, 1]]:
		var p := world_pos_of(cell[0], cell[1])
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	var pad := Vector2(K.TILE_W, K.TILE_H)
	return Rect2(mn - pad * 0.5, (mx - mn) + pad)


## 六边形顶点（用于 footprint 描边）
func hex_points(col: int, row: int) -> PackedVector2Array:
	var c := world_pos_of(col, row)
	var pts := PackedVector2Array()
	var rx := float(K.TILE_W) * 0.5
	var ry := float(K.TILE_H) * 0.5
	for i in range(6):
		var ang := deg_to_rad(60.0 * float(i) - 90.0)
		pts.append(c + Vector2(rx * cos(ang), ry * sin(ang)))
	return pts


func _draw() -> void:
	if not show_coords:
		return
	var f := ThemeDB.fallback_font
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var p := world_pos_of(col, row)
			draw_string(f, p + Vector2(-22, 5), "(%d,%d)" % [col, row],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, 0.55))


func toggle_coords() -> void:
	show_coords = not show_coords
	queue_redraw()
