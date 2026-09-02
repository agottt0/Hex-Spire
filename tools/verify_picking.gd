extends SceneTree
## 透视下的【鼠标拾取】正确性校验
##
## 这是透视改造里风险最高的一环。原先 cell_at_mouse() 靠
## TileMapLayer.local_to_map()（引擎实现，必对）；现在改成
##   屏幕 → 逆单应 → 最近格心 → 点在多边形内
## 三步全是自己写的。错了的表现是"点了但打不到"或"打到隔壁格" ——
## 战棋里这是致命 bug，且**截图完全看不出来**，只能靠这个测试钉死。
##
## 覆盖 49 格格心 + 294 次格内抖动 + 6 个界外点 + 平面回退模式。
##
## ⚠️ 改 hex_board_view.cell_at_mouse / flat_pos_of / FLOOR_QUAD_UV 后必须重跑。
##
## 跑法：godot --headless --path . -s res://tools/verify_picking.gd
## 退出码 0 = 全部通过。

var fails := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  ✓ %s  %s" % [name, detail])
	else:
		print("  ✗ %s  %s" % [name, detail])
		fails += 1


## 复刻 cell_at_mouse 的判定，但以传入的屏幕点取代鼠标位置
func _pick(board: HexBoardView, screen: Vector2) -> Vector2i:
	var flat := board.projection.unproject(screen)
	var best := Vector2i(-1, -1)
	var best_d := INF
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var d := flat.distance_squared_to(board.flat_pos_of(col, row))
			if d < best_d:
				best_d = d
				best = Vector2i(col, row)
	if best.x < 0:
		return Vector2i(-1, -1)
	if not Geometry2D.is_point_in_polygon(flat,
			board.flat_hex_points(best.x, best.y)):
		return Vector2i(-1, -1)
	return best


func _initialize() -> void:
	print("=== 透视拾取校验 ===")
	print("")

	var board := HexBoardView.new()
	# 模拟 battle_scene 注入的地板四边形（背景 2048×1152 居中于原点、scale 1）
	var br := Rect2(Vector2(-1024, -576), Vector2(2048, 1152))
	var quad: Array = []
	for uv in HexBoardView.FLOOR_QUAD_UV:
		var t: Vector2 = uv
		quad.append(br.position + Vector2(br.size.x * t.x, br.size.y * t.y))
	board.set_floor_quad(quad)
	_check("投影已建立", board.projection.is_valid())

	# ---- 1. 每格格心必须拾取回自己（49/49）
	var wrong := 0
	var first_bad := ""
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var screen := board.world_pos_of(col, row)
			var got := _pick(board, screen)
			if got != Vector2i(col, row):
				wrong += 1
				if first_bad == "":
					first_bad = "(%d,%d) -> %s" % [col, row, str(got)]
	_check("49 格格心各自命中", wrong == 0,
		"错 %d 处 %s" % [wrong, first_bad])

	# ---- 2. 格内抖动仍命中（模拟玩家点不准）
	#      沿 6 个方向偏移到格内 55% 半径处
	var jitter_wrong := 0
	var jbad := ""
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var center := board.flat_pos_of(col, row)
			for i in range(6):
				var ang := deg_to_rad(60.0 * float(i))
				var off := Vector2(cos(ang), sin(ang)) \
					* float(K.TILE_W) * 0.5 * 0.55
				var screen := board.projection.project(center + off)
				var got := _pick(board, screen)
				if got != Vector2i(col, row):
					jitter_wrong += 1
					if jbad == "":
						jbad = "(%d,%d)+dir%d -> %s" % [col, row, i, str(got)]
	_check("格内抖动 294 次全部命中", jitter_wrong == 0,
		"错 %d 处 %s" % [jitter_wrong, jbad])

	# ---- 3. 界外点必须返回 (-1,-1)，不能吸附到边缘格
	var leak := 0
	var fb := board.projection.projected_bounds()
	var outside := [
		fb.position + Vector2(-260, -260),
		fb.position + Vector2(fb.size.x + 260, -260),
		fb.position + Vector2(-260, fb.size.y + 260),
		fb.position + Vector2(fb.size.x + 260, fb.size.y + 260),
		fb.position + Vector2(fb.size.x * 0.5, -300),
		fb.position + Vector2(fb.size.x * 0.5, fb.size.y + 300),
	]
	for p in outside:
		if _pick(board, p) != Vector2i(-1, -1):
			leak += 1
	_check("界外点击不吸附", leak == 0, "泄漏 %d 处" % leak)

	# ---- 4. 相邻格不得映射到同一格（透视挤压下最容易出的问题）
	var dup := {}
	var collide := 0
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			var key := str(_pick(board, board.world_pos_of(col, row)))
			if dup.has(key):
				collide += 1
			dup[key] = true
	_check("49 格互不重叠（无挤压塌陷）", collide == 0 and dup.size() == 49,
		"唯一命中 %d 个" % dup.size())

	# ---- 5. 远排格子仍有可点面积（可玩性下限）
	#      量最远一排格子的投影后屏幕高度
	var far_poly := board.hex_points(4, HexCoord.ROWS)
	var near_poly := board.hex_points(4, 1)
	var far_h := _poly_h(far_poly)
	var near_h := _poly_h(near_poly)
	var far_w := _poly_w(far_poly)
	_check("最远排格高 ≥14px（可点）", far_h >= 14.0,
		"远 %.1fpx  近 %.1fpx" % [far_h, near_h])
	_check("最远排格宽 ≥40px（可读）", far_w >= 40.0, "= %.1fpx" % far_w)

	# ---- 6. 无投影（回退平面）时拾取同样成立
	var flat_board := HexBoardView.new()
	flat_board.set_floor_quad([])
	var flat_wrong := 0
	for row in range(1, HexCoord.ROWS + 1):
		for col in range(1, HexCoord.COLS + 1):
			if _pick(flat_board, flat_board.world_pos_of(col, row)) \
					!= Vector2i(col, row):
				flat_wrong += 1
	_check("平面回退模式下拾取仍正确", flat_wrong == 0, "错 %d 处" % flat_wrong)

	print("")
	print("========== 总失败数: %d ==========" % fails)
	quit(1 if fails > 0 else 0)


static func _poly_h(poly: PackedVector2Array) -> float:
	var mn := INF
	var mx := -INF
	for p in poly:
		mn = minf(mn, p.y)
		mx = maxf(mx, p.y)
	return mx - mn


static func _poly_w(poly: PackedVector2Array) -> float:
	var mn := INF
	var mx := -INF
	for p in poly:
		mn = minf(mn, p.x)
		mx = maxf(mx, p.x)
	return mx - mn
