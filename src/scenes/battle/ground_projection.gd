class_name GroundProjection
## 地板平面 → 屏幕的透视投影（单应变换）。表现层专属，core 不引用。
##
## ════════════════════════════════════════════════════════════════════
## 这个类存在的理由
## ════════════════════════════════════════════════════════════════════
##
## 背景 `Chapter1_BattleScene.png` 是一张有真透视的地铁站台：地砖向消隐点收敛，
## 中间亮区远边宽度只有近边的约 50%。原先的战场是【平的】，直接叠上去像贴纸。
##
## TileMapLayer 渲染是纯仿射的（Node2D 的 Transform2D 没有透视除法），做不到
## 逐顶点除 w。所以战场改为手绘六边形，几何全部经本类投影。
##
## ⚠️ 这不是"美化"，它会动到玩法可读性 —— 见下面的强度取舍。
##
## ── 数学：矩形 → 四边形的单应闭式解 ──────────────────────────────
##
## 源是轴对齐矩形（平面战场的外接框），目标是任意凸四边形（背景地板区）。
## 这种特殊情形有闭式解，不需要解 8×8 线性系统、不引矩阵库：
##
##   先把源点归一化到单位正方形 (0,0)-(1,1)，再套 unit-square → quad 的公式。
##
##   screen = ( (a·u + b·v + c) / (g·u + h·v + 1),
##              (d·u + e·v + f) / (g·u + h·v + 1) )
##
## 其中 w = g·u + h·v + 1 就是透视除数。**1/w 同时也是该处的深度缩放** ——
## 单位 sprite、接地阴影的压扁比全部复用它，这样人、影、格子三者永远一致。
##
## ── 强度取舍：为什么不是"把四边形插值成矩形" ─────────────────────
##
## 完全贴合地板 = 顶行格宽只有底行的一半。后果：
##   · 顶行敌人 sprite 要缩到 47%，意图图标/HP 条跟着缩 → 违反美术文档 V3
##   · 「射程 3 格」朝上覆盖的屏幕距离远小于朝两侧 → 玩家误判
##
## ⚠️ 我第一版用「目标四边形往同面积矩形插值」来削弱透视，**这是错的**：
##   插值保住了占屏面积，却把四角挪离了地板平面 —— 结果 strength=0.55 时
##   网格既不平也不贴地，直接盖在列车和天花板上（实测截图确认）。
##
## 正确做法是两个正交的旋钮，**四角永远留在地板平面上**：
##   ① depth_span（本类的 setup 参数由调用方给定四边形时控制）：
##      网格只占用地板【近侧一段深度】。远边落在地板更宽处 → 收敛自然变缓，
##      且四角依旧在地板上。
##   ② unit_depth_influence（表现层用）：单位尺寸按
##      lerp(1.0, 真实深度缩放, influence) 取值。
##      地面走满透视（看起来真的躺在地砖上），单位缩放弱化（保住可读性）。
##      这是 2.5D 游戏的标准手法：地面全透视 + 角色欠透视。

## 单位正方形 → 四边形的 8 个系数
var _a := 1.0
var _b := 0.0
var _c := 0.0
var _d := 0.0
var _e := 1.0
var _f := 0.0
var _g := 0.0
var _h := 0.0

## 源矩形（平面战场外接框），用于归一化
var _src := Rect2(0, 0, 1, 1)

## 参考深度除数：深度缩放以此为 1.0。取源矩形底边中点（最近处）。
var _w_ref := 1.0

var _valid := false


func is_valid() -> bool:
	return _valid


## 构建投影。
##   src  : 平面战场的外接矩形（未投影空间）
##   quad : 目标四边形，顺序必须为 [左上, 右上, 右下, 左下]（屏幕坐标）
##
## quad 的四角【就是】网格四角，不做任何形状插值 ——
## 削弱透视请由调用方在传入前收缩 quad 的深度（见 shrink_depth）。
func setup(src: Rect2, quad: Array) -> void:
	_valid = false
	if src.size.x <= 0.0 or src.size.y <= 0.0 or quad.size() != 4:
		return

	_src = src

	# unit square → quad 的闭式解
	# 顶点约定：p0=左上(0,0)  p1=右上(1,0)  p2=右下(1,1)  p3=左下(0,1)
	var p0: Vector2 = quad[0]
	var p1: Vector2 = quad[1]
	var p2: Vector2 = quad[2]
	var p3: Vector2 = quad[3]

	var dx1 := p1.x - p2.x
	var dy1 := p1.y - p2.y
	var dx2 := p3.x - p2.x
	var dy2 := p3.y - p2.y
	var sx := p0.x - p1.x + p2.x - p3.x
	var sy := p0.y - p1.y + p2.y - p3.y

	var den := dx1 * dy2 - dx2 * dy1
	if absf(den) < 1e-9:
		return   # 退化四边形

	_g = (sx * dy2 - dx2 * sy) / den
	_h = (dx1 * sy - sx * dy1) / den
	_a = p1.x - p0.x + _g * p1.x
	_b = p3.x - p0.x + _h * p3.x
	_c = p0.x
	_d = p1.y - p0.y + _g * p1.y
	_e = p3.y - p0.y + _h * p3.y
	_f = p0.y

	# 参考 w 取源矩形底边中点（画面最近处），使近处深度缩放 ≈ 1.0
	_w_ref = maxf(_w_of_uv(0.5, 1.0), 1e-6)
	_valid = true


## 把地板四边形沿【地板平面】收缩深度：远边朝近边移动。
##
## span=1 → 用满整块地板；span=0.6 → 只用近侧 60% 的深度。
## 关键性质：**四角始终留在原地板平面内**（因为是在四边形自身的边上插值），
## 所以网格依然严格躺在地砖上，只是占的纵深变短、收敛变缓。
## 这是"削弱透视但不失去贴地"的唯一正确做法。
static func shrink_depth(quad: Array, span: float) -> Array:
	if quad.size() != 4:
		return quad
	var s := clampf(span, 0.05, 1.0)
	var tl: Vector2 = quad[0]
	var tr: Vector2 = quad[1]
	var br: Vector2 = quad[2]
	var bl: Vector2 = quad[3]
	return [bl.lerp(tl, s), br.lerp(tr, s), br, bl]


func _to_uv(p: Vector2) -> Vector2:
	return Vector2(
		(p.x - _src.position.x) / _src.size.x,
		(p.y - _src.position.y) / _src.size.y)


func _w_of_uv(u: float, v: float) -> float:
	return _g * u + _h * v + 1.0


## 平面点 → 屏幕点
func project(p: Vector2) -> Vector2:
	if not _valid:
		return p
	var uv := _to_uv(p)
	var w := _w_of_uv(uv.x, uv.y)
	if absf(w) < 1e-9:
		return p
	return Vector2(
		(_a * uv.x + _b * uv.y + _c) / w,
		(_d * uv.x + _e * uv.y + _f) / w)


## 屏幕点 → 平面点（鼠标拾取用）
##
## 解 2×2 线性系统而非显式求逆矩阵：把
##   (a·u + b·v + c) = X·(g·u + h·v + 1)
##   (d·u + e·v + f) = Y·(g·u + h·v + 1)
## 整理成 u、v 的线性方程即可。
func unproject(s: Vector2) -> Vector2:
	if not _valid:
		return s
	var a11 := _a - s.x * _g
	var a12 := _b - s.x * _h
	var b1 := s.x - _c
	var a21 := _d - s.y * _g
	var a22 := _e - s.y * _h
	var b2 := s.y - _f

	var den := a11 * a22 - a12 * a21
	if absf(den) < 1e-9:
		return s
	var u := (b1 * a22 - a12 * b2) / den
	var v := (a11 * b2 - b1 * a21) / den
	return Vector2(
		_src.position.x + u * _src.size.x,
		_src.position.y + v * _src.size.y)


## 某平面点处的深度缩放（近 ≈1.0，远 <1.0）。地面几何用它。
func depth_scale(p: Vector2) -> float:
	if not _valid:
		return 1.0
	var uv := _to_uv(p)
	var w := _w_of_uv(uv.x, uv.y)
	if absf(w) < 1e-9:
		return 1.0
	return clampf(_w_ref / w, 0.05, 4.0)


## 单位/UI 用的【弱化】深度缩放 = lerp(1.0, 真实值, influence)。
##
## influence=1 是物理正确的，但远处敌人会缩到约 50%，HP 条与意图图标随之
## 不可读 —— 违反美术文档「缩到 25% 仍分得清体型/危害格」的验收线。
## 地面走满透视 + 角色欠透视是 2.5D 的标准取舍：贴地感来自地面，
## 可读性来自角色。
func unit_depth_scale(p: Vector2, influence: float) -> float:
	return lerpf(1.0, depth_scale(p), clampf(influence, 0.0, 1.0))


## 投影后四角的屏幕 AABB（相机取景用）
func projected_bounds() -> Rect2:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for c in [_src.position,
			_src.position + Vector2(_src.size.x, 0.0),
			_src.position + _src.size,
			_src.position + Vector2(0.0, _src.size.y)]:
		var p := project(c)
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)
