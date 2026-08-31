class_name GreyboxTileSet
## 运行时生成六边形 TileSet —— 零美术资产（§14 红线）
##
## 一张 128×148 的白色六边形贴图 + 12 个 alternative tile，
## 每个 alt 只改 TileData.modulate → 一张图搞定全部外观。
## 不进任何图片文件到版本库。
##
## 尺寸依据：美术文档 §9.1（尖顶六边形，高 = 宽 × 2/√3 = 147.8 → 148）

# alt 索引 → 语义
enum Alt {
	FLOOR = 0,
	WALL = 1,
	PIT = 2,
	RUBBLE = 3,
	EXIT_GATE = 4,
	HAZARD_SPIKES = 5,
	HAZARD_FIRE = 6,
	HL_LEGAL = 7,        ## 合法目标（青）
	HL_AFFECTED = 8,     ## 波及范围（橙）
	HL_INTENT = 9,       ## 敌人意图（红）
	HL_MOVE_OK = 10,     ## 落点合法（绿）
	HL_MOVE_BAD = 11,    ## 落点非法（红）
}

## 灰盒配色。功能色遵守美术文档 §4.4：
##   地面高亮只许两种语义色（青=合法/己方，红=危险/非法），其余走 UI
const COLORS := {
	Alt.FLOOR: Color("#3A3A40"),
	Alt.WALL: Color("#141418"),
	Alt.PIT: Color("#05050A"),
	Alt.RUBBLE: Color("#4A4038"),
	Alt.EXIT_GATE: Color("#B8A038"),
	Alt.HAZARD_SPIKES: Color("#6B1F1F"),
	Alt.HAZARD_FIRE: Color("#8A4A1C"),
	Alt.HL_LEGAL: Color(0.24, 0.84, 0.82, 0.45),
	Alt.HL_AFFECTED: Color(1.0, 0.62, 0.20, 0.45),
	Alt.HL_INTENT: Color(1.0, 0.23, 0.19, 0.50),
	Alt.HL_MOVE_OK: Color(0.35, 0.85, 0.45, 0.55),
	Alt.HL_MOVE_BAD: Color(1.0, 0.23, 0.19, 0.55),
}


static func build() -> TileSet:
	var ts := TileSet.new()
	# §14.3 原文配置：尖顶六边形 + odd-r 堆叠
	ts.tile_shape = TileSet.TILE_SHAPE_HEXAGON
	ts.tile_layout = TileSet.TILE_LAYOUT_STACKED
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL
	ts.tile_size = Vector2i(K.TILE_W, K.TILE_H)

	var src := TileSetAtlasSource.new()
	src.texture = _make_hex_texture()
	src.texture_region_size = Vector2i(K.TILE_W, K.TILE_H)
	src.create_tile(Vector2i.ZERO)

	# 基础 tile（alt 0）= FLOOR
	var base: TileData = src.get_tile_data(Vector2i.ZERO, 0)
	base.modulate = COLORS[Alt.FLOOR]

	# 其余 alt
	var max_alt: int = Alt.HL_MOVE_BAD
	for i in range(1, max_alt + 1):
		var alt_id := src.create_alternative_tile(Vector2i.ZERO, i)
		var td: TileData = src.get_tile_data(Vector2i.ZERO, alt_id)
		td.modulate = COLORS.get(i, Color.WHITE)

	ts.add_source(src, 0)
	return ts


## 画一个尖顶六边形（白色不透明，外部透明，边缘 1px 羽化）
static func _make_hex_texture() -> ImageTexture:
	var w := K.TILE_W
	var h := K.TILE_H
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var cx := float(w) * 0.5
	var cy := float(h) * 0.5
	# 尖顶六边形的 6 个顶点（上下为尖）
	var verts: Array[Vector2] = []
	for i in range(6):
		var ang := deg_to_rad(60.0 * float(i) - 90.0)
		verts.append(Vector2(cx + cx * cos(ang), cy + cy * sin(ang)))

	for y in range(h):
		for x in range(w):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var d := _signed_dist_to_hex(p, verts)
			if d <= 0.0:
				# 内部：靠边缘 1.5px 做羽化，避免锯齿
				var a := clampf(-d / 1.5, 0.0, 1.0)
				img.set_pixel(x, y, Color(1, 1, 1, maxf(a, 0.35)))
	return ImageTexture.create_from_image(img)


## 点到凸多边形的带符号距离（内负外正）
static func _signed_dist_to_hex(p: Vector2, verts: Array[Vector2]) -> float:
	var max_d := -1e9
	var n := verts.size()
	for i in range(n):
		var a := verts[i]
		var b := verts[(i + 1) % n]
		var edge := b - a
		# 外法线（顶点按顺时针排列时）
		var nrm := Vector2(edge.y, -edge.x).normalized()
		var d := (p - a).dot(nrm)
		max_d = maxf(max_d, d)
	return max_d


## Terrain 枚举 → alt 索引
static func alt_for_terrain(t: GameEnums.Terrain) -> int:
	match t:
		GameEnums.Terrain.WALL: return Alt.WALL
		GameEnums.Terrain.PIT: return Alt.PIT
		GameEnums.Terrain.RUBBLE: return Alt.RUBBLE
		GameEnums.Terrain.EXIT_GATE: return Alt.EXIT_GATE
		_: return Alt.FLOOR


static func alt_for_hazard(hz: GameEnums.Hazard) -> int:
	match hz:
		GameEnums.Hazard.FIRE: return Alt.HAZARD_FIRE
		GameEnums.Hazard.NONE: return -1
		_: return Alt.HAZARD_SPIKES
