extends SceneTree
## 地面透视投影的数学校验（GroundProjection）
##
## 战场从"平面 TileMapLayer"改为"贴合背景地板的单应投影"后，几何全部由
## 自己写的 3×3 单应承担。这里把数学钉死：四角贴合、往返一致、深度单调、
## shrink_depth 不脱离地板平面、退化输入不崩。
##
## ⚠️ 改 GroundProjection 或 FLOOR_QUAD_UV 后必须重跑。
##
## 跑法：godot --headless --path . -s res://tools/verify_projection.gd
## 退出码 0 = 全部通过。

var fails := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  ✓ %s  %s" % [name, detail])
	else:
		print("  ✗ %s  %s" % [name, detail])
		fails += 1


func _initialize() -> void:
	var src := Rect2(0, 0, 896, 1036)   # 约等于 7×7 平面战场外接框
	# 目标四边形：模拟背景中间亮区（远边约为近边一半）
	var quad := [
		Vector2(660, 330),    # 左上（远）
		Vector2(1470, 330),   # 右上（远）
		Vector2(1935, 1060),  # 右下（近）
		Vector2(300, 1060),   # 左下（近）
	]

	print("=== GroundProjection 数学校验 ===")
	print("")

	# ---- 1. 四角精确贴合
	var gp := GroundProjection.new()
	gp.setup(src, quad)
	_check("setup 有效", gp.is_valid())

	var corners := [
		src.position,
		src.position + Vector2(src.size.x, 0),
		src.position + src.size,
		src.position + Vector2(0, src.size.y),
	]
	var max_corner_err := 0.0
	for i in range(4):
		var got := gp.project(corners[i])
		max_corner_err = maxf(max_corner_err, (got - quad[i]).length())
	_check("四角贴合目标四边形", max_corner_err < 0.01,
		"最大误差 %.6f px" % max_corner_err)

	# ---- 2. 往返一致（覆盖整个战场，含边界）
	var max_rt := 0.0
	var worst := ""
	for iy in range(11):
		for ix in range(11):
			var p := src.position + Vector2(
				src.size.x * float(ix) / 10.0,
				src.size.y * float(iy) / 10.0)
			var back := gp.unproject(gp.project(p))
			var err := (back - p).length()
			if err > max_rt:
				max_rt = err
				worst = "%s -> %s" % [str(p), str(back)]
	_check("project/unproject 往返一致", max_rt < 0.01,
		"最大误差 %.6f px  %s" % [max_rt, worst if max_rt >= 0.01 else ""])

	# ---- 3. 深度缩放单调（v 越小=越远，缩放越小）
	var prev := -1.0
	var mono := true
	var samples: Array[String] = []
	for iy in range(6):
		var v := float(iy) / 5.0
		var p := src.position + Vector2(src.size.x * 0.5, src.size.y * v)
		var ds := gp.depth_scale(p)
		samples.append("%.2f" % ds)
		if ds < prev - 1e-6:
			mono = false
		prev = ds
	_check("深度缩放随距离单调递增", mono, "远→近: " + " ".join(samples))

	# 近处应 ≈1.0
	var near_ds := gp.depth_scale(src.position + Vector2(src.size.x * 0.5, src.size.y))
	_check("近边深度缩放 ≈1.0", absf(near_ds - 1.0) < 0.01, "= %.4f" % near_ds)

	# 远处应明显小于近处（说明透视真的生效了）
	var far_ds := gp.depth_scale(src.position + Vector2(src.size.x * 0.5, 0.0))
	_check("远边明显小于近边", far_ds < 0.75, "远 = %.4f" % far_ds)

	# ---- 4. shrink_depth：四角必须仍在原地板平面内，且收敛变缓
	var shrunk := GroundProjection.shrink_depth(quad, 0.78)
	# 近边两角不动
	_check("shrink_depth 近边两角不变",
		(shrunk[2] as Vector2).is_equal_approx(quad[2])
		and (shrunk[3] as Vector2).is_equal_approx(quad[3]))
	# 远边两角必须落在原四边形的侧边上（= 仍在地板平面内）
	var on_left := Geometry2D.get_closest_point_to_segment(
		shrunk[0], quad[3], quad[0]).distance_to(shrunk[0])
	var on_right := Geometry2D.get_closest_point_to_segment(
		shrunk[1], quad[2], quad[1]).distance_to(shrunk[1])
	_check("shrink_depth 远边两角仍在地板侧边上",
		on_left < 0.01 and on_right < 0.01,
		"左偏 %.6f  右偏 %.6f" % [on_left, on_right])

	var gp_s := GroundProjection.new()
	gp_s.setup(src, shrunk)
	var s_t := (gp_s.project(src.position + Vector2(src.size.x, 0))
		- gp_s.project(src.position)).length()
	var s_b := (gp_s.project(src.position + src.size)
		- gp_s.project(src.position + Vector2(0, src.size.y))).length()
	var full_ratio := (quad[1] as Vector2).distance_to(quad[0]) \
		/ (quad[2] as Vector2).distance_to(quad[3])
	var s_ratio := s_t / maxf(s_b, 1e-6)
	_check("shrink_depth 收敛比优于用满地板",
		s_ratio > full_ratio, "span=0.78 → %.3f  vs 用满 %.3f" % [s_ratio, full_ratio])

	# ---- 5. 单位弱化缩放
	var far_p := src.position + Vector2(src.size.x * 0.5, 0.0)
	var raw := gp.depth_scale(far_p)
	var weak := gp.unit_depth_scale(far_p, 0.62)
	_check("单位弱化缩放介于 1.0 与真实值之间",
		weak > raw and weak < 1.0, "真实 %.3f → 弱化 %.3f" % [raw, weak])
	_check("influence=0 时单位不缩放",
		absf(gp.unit_depth_scale(far_p, 0.0) - 1.0) < 1e-6)
	_check("influence=1 时等于真实值",
		absf(gp.unit_depth_scale(far_p, 1.0) - raw) < 1e-6)

	# ---- 6. 退化输入不崩
	var gpx := GroundProjection.new()
	gpx.setup(Rect2(0, 0, 0, 0), quad)
	_check("零面积源矩形 → 判为无效", not gpx.is_valid())
	var passthrough := gpx.project(Vector2(12, 34))
	_check("无效投影时原样返回", passthrough == Vector2(12, 34))
	_check("无效投影时深度缩放恒 1",
		absf(gpx.depth_scale(Vector2(12, 34)) - 1.0) < 1e-9)

	print("")
	print("========== 总失败数: %d ==========" % fails)
	quit(1 if fails > 0 else 0)
