class_name UnitSprites
## 单位美术资产的运行时装配 —— 表现层专属，core 不引用
##
## ════════════════════════════════════════════════════════════════════
## 为什么在运行时生成 SpriteFrames，而不提交 .tres
## ════════════════════════════════════════════════════════════════════
##
## `Art/Character/<角色>/{Idle,Move,Attack}/image_N.png` 是【按紧包围盒裁剪】过的，
## 同一段动画内各帧画布尺寸并不相同。实测：
##
##   镇妖者/Idle   [6f] → 512x512（整齐）
##   镇妖者/Move   [8f] → 384x512（整齐）
##   镇妖者/Attack [7f] → 241x410 / 405x323 / 304x459 / … / 457x429   ← 每帧都不同
##   御灵者/Move   [8f] → 299x457 / 251x477 / … 八种尺寸
##   妖化者/Idle   [6f] → 239x559 / 242x552 / … 六种尺寸
##
## 若把这些图直接塞进 `AnimatedSprite2D`，各帧会按【自身画布中心】对齐 ——
## 播放时角色会剧烈漂移、忽高忽低，攻击动作尤其明显（宽度从 241 跳到 457）。
##
## 而且尺寸"整齐"的那几段也不能直接用：512x512 是【未裁剪】的原始画布，
## 角色脚底在画布内的位置未知；裁剪过的帧则底边就是脚底。
## 两类混用 → Idle 与 Attack 之间脚底不在同一高度，切换动画时角色会突然升降。
##
## ── 解法：统一到「脚底锚点」───────────────────────────────────────
##
## 1. 用 `Image.get_used_rect()`（引擎内置 C++，很快）测出每帧**真实内容框**，
##    从而抹平"已裁剪 / 未裁剪"的差异。
## 2. 取内容框底部 FOOT_SLICE_RATIO 的切片，算其水平中心 = **脚部中心**。
##    不用整帧的水平中心 —— 那会被横挥的武器拉偏，导致身体左右晃。
## 3. 以 (脚部中心 x, 内容框底边 y) 为锚点，用 `AtlasTexture.region + margin`
##    把每帧重放到一块【跨全部动画共享】的统一画布上，锚点固定落在
##    画布的 (水平正中, 底边)。
##
## 于是：帧间零漂移、动画间零跳变、且 sprite 的 position 就是脚底
## （对齐美术文档 §9.1「单位锚点 = tile 底部中心」）。
##
## 写死 .tres 需要手工维护近百个资源并逐帧算 margin，成本与出错率都高得多。
## 这与 `greybox_tileset.gd` 运行时生成 TileSet 是同一思路。

const CHAR_ROOT := "res://Art/Character/"

## source_id → 角色资产目录名
##
## 灰盒期的语义映射（内容扩充后可调整，不影响逻辑层）：
##   knight        持盾镇守 ↔ 被动「格挡不清空」
##   giant         M 体型，需要完整三套动画
##   stone_slinger 远程施法 ↔ RANGED_KITER
##   biting_hound  妖化扑咬（该资产缺 Attack，自动回退 idle）
##
## 未列出的单位（stone_golem / siege_worm）继续走 UnitView 的灰盒绘制 ——
## 缺资产不是错误状态，回退路径必须存在。
const UNIT_ART := {
	"knight": "镇妖者",
	"giant": "御灵者",
	"stone_slinger": "术士",
	"biting_hound": "妖化者",
}

## 动画名 → 资产子目录
const ANIM_DIRS := {
	"idle": "Idle",
	"move": "Move",
	"attack": "Attack",
}

## 每段动画的播放帧率。
## attack 刻意压到让整段 ≤0.4 秒（美术文档 R8：战斗特效时长 ≤0.4s 且可跳过）。
const ANIM_FPS := {
	"idle": 6.0,
	"move": 10.0,
	"attack": 20.0,
}

const ANIM_LOOP := {
	"idle": true,
	"move": true,
	"attack": false,
}

## 单帧序列的安全上限，防目录异常导致死循环
const MAX_FRAMES := 64

## 取内容框底部这个比例作为"脚部"来定位水平锚点。
## 太小 → 采样噪声敏感；太大 → 又会被武器/披风拉偏。
const FOOT_SLICE_RATIO := 0.18

## 画布四周留的余量（像素），避免描边/羽化被裁到边
const CANVAS_PAD := 4

# ------------------------------------------------------------------ 缓存
# 一场战斗最多 4 种资产，按需构建 + 永久缓存。
# 静态缓存跨场景复用，重开战斗不重复扫像素。

static var _frames_cache: Dictionary = {}
static var _portrait_cache: Dictionary = {}
static var _canvas_cache: Dictionary = {}


## 该单位有没有配美术资产。没有 → 调用方走灰盒回退。
static func has_art(source_id: String) -> bool:
	return UNIT_ART.has(source_id)


## 取装配好的 SpriteFrames。无资产或加载失败返回 null（调用方必须处理）。
static func frames_for(source_id: String) -> SpriteFrames:
	if not UNIT_ART.has(source_id):
		return null
	var art_dir: String = UNIT_ART[source_id]
	if _frames_cache.has(art_dir):
		return _frames_cache[art_dir]
	var sf := _build_frames(art_dir)
	_frames_cache[art_dir] = sf
	return sf


## 统一画布尺寸（供调用方算缩放与 offset）。frames_for 之后才有效。
static func canvas_size(source_id: String) -> Vector2i:
	if not UNIT_ART.has(source_id):
		return Vector2i.ZERO
	return _canvas_cache.get(UNIT_ART[source_id], Vector2i.ZERO)


## 立绘 / 头像。
##
## ⚠️ 候选顺序不能反：`立绘.png` 对部分角色是【角色设定集】而非立绘 ——
##   镇妖者/立绘.png 是 1536×1024 的设计稿（含三视图、配色表、材质参考），
##   放进面板就是一张缩得看不清的拼版图。实测踩过。
##   `<角色名>.png` 才是去背的单人立绘（1254×1254），所以它排第一。
static func portrait_for(source_id: String) -> Texture2D:
	if not UNIT_ART.has(source_id):
		return null
	var art_dir: String = UNIT_ART[source_id]
	if _portrait_cache.has(art_dir):
		return _portrait_cache[art_dir]
	var tex: Texture2D = null
	for candidate in [art_dir + ".png", "立绘.png"]:
		var p: String = CHAR_ROOT + art_dir + "/" + str(candidate)
		if ResourceLoader.exists(p):
			tex = load(p) as Texture2D
			if tex != null:
				break
	_portrait_cache[art_dir] = tex
	return tex


# ══════════════════════════════════════════════════════ 装配

static func _build_frames(art_dir: String) -> SpriteFrames:
	# 1. 先把所有动画的所有帧读进来并测量，才能定出【跨动画共享】的画布
	var seqs: Dictionary = {}      ## anim -> Array[Dictionary{tex, used, foot_cx}]
	for anim in ANIM_DIRS:
		var metas := _measure_sequence(art_dir, ANIM_DIRS[anim])
		if not metas.is_empty():
			seqs[anim] = metas

	if seqs.is_empty():
		push_warning("[UnitSprites] %s 没有可用帧，回退灰盒" % art_dir)
		return null

	var canvas := _compute_canvas(seqs)
	_canvas_cache[art_dir] = canvas

	# 2. 按统一画布装配
	var sf := SpriteFrames.new()
	# SpriteFrames 默认自带一个空的 "default" 动画，先移掉避免误播
	if sf.has_animation("default"):
		sf.remove_animation("default")

	for anim in ["idle", "move", "attack"]:
		if not seqs.has(anim):
			continue
		sf.add_animation(anim)
		sf.set_animation_speed(anim, ANIM_FPS[anim])
		sf.set_animation_loop(anim, ANIM_LOOP[anim])
		for meta in seqs[anim]:
			sf.add_frame(anim, _wrap_aligned(meta, canvas))

	# 3. 缺失动画的回退链：move/attack 缺了就复用 idle，
	#    让调用方任何时候都能安全 play()（妖化者没有 Attack 目录）
	var fallback := "idle" if sf.has_animation("idle") else sf.get_animation_names()[0]
	for anim in ["idle", "move", "attack"]:
		if not sf.has_animation(anim):
			_alias_animation(sf, fallback, anim)

	return sf


## 读一段序列并测量每帧的内容框与脚部中心
static func _measure_sequence(art_dir: String, sub: String) -> Array:
	var out: Array = []
	var i := 1
	while i <= MAX_FRAMES:
		var p := "%s%s/%s/image_%d.png" % [CHAR_ROOT, art_dir, sub, i]
		if not ResourceLoader.exists(p):
			break
		var tex := load(p) as Texture2D
		if tex == null:
			break
		var meta := _measure_frame(tex)
		if not meta.is_empty():
			out.append(meta)
		i += 1
	return out


## 测量单帧：真实内容框 + 脚部水平中心
static func _measure_frame(tex: Texture2D) -> Dictionary:
	var img := tex.get_image()
	if img == null:
		# 拿不到像素（异常导入）→ 退化为"整张图 + 几何中心"
		return {
			"tex": tex,
			"used": Rect2i(0, 0, tex.get_width(), tex.get_height()),
			"foot_cx": float(tex.get_width()) * 0.5,
		}
	if img.is_compressed():
		# VRAM 压缩格式下 get_used_rect 不可靠，先解压
		if img.decompress() != OK:
			return {
				"tex": tex,
				"used": Rect2i(0, 0, tex.get_width(), tex.get_height()),
				"foot_cx": float(tex.get_width()) * 0.5,
			}

	var used := img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return {}   # 全透明帧，丢弃

	# 脚部切片的水平中心：抗"武器横挥把包围盒中心拉偏"
	var foot_h: int = maxi(1, int(round(float(used.size.y) * FOOT_SLICE_RATIO)))
	var foot_cx := float(used.position.x) + float(used.size.x) * 0.5
	var slice_rect := Rect2i(
		used.position.x, used.position.y + used.size.y - foot_h,
		used.size.x, foot_h)
	var slice := img.get_region(slice_rect)
	if slice != null:
		var su := slice.get_used_rect()
		if su.size.x > 0:
			foot_cx = float(used.position.x + su.position.x) + float(su.size.x) * 0.5

	return {"tex": tex, "used": used, "foot_cx": foot_cx}


## 由全部帧算出共享画布：锚点在 (水平正中, 底边)，需容纳最大左右延伸与最大高度
##
## 垂直方向【不加余量】—— 画布高必须等于最高帧的内容高，
## 这样调用方用 `target_h / canvas.y` 算缩放才精确对应角色身高。
static func _compute_canvas(seqs: Dictionary) -> Vector2i:
	var half := 1.0
	var height := 1.0
	# 遍历顺序不影响结果（只取 max），确定性无风险
	for anim in seqs:
		for meta in seqs[anim]:
			var used: Rect2i = meta["used"]
			var cx: float = meta["foot_cx"]
			half = maxf(half, cx - float(used.position.x))                        # 锚点到左边
			half = maxf(half, float(used.position.x + used.size.x) - cx)          # 锚点到右边
			height = maxf(height, float(used.size.y))
	return Vector2i(int(ceil(half * 2.0)) + CANVAS_PAD * 2, int(ceil(height)))


## 把一帧重放到统一画布：只取内容区，用 margin 补足留白
##
## AtlasTexture 语义：
##   总尺寸   = region.size + margin.size
##   内容偏移 = margin.position
## 所以「水平居中 + 底边对齐」= margin.position 取 (画布中心 - 锚点到左缘, 画布高 - 内容高)
static func _wrap_aligned(meta: Dictionary, canvas: Vector2i) -> Texture2D:
	var used: Rect2i = meta["used"]
	var cx: float = meta["foot_cx"]
	var left_ext := cx - float(used.position.x)     # 锚点到内容左缘的距离

	var off_x := float(canvas.x) * 0.5 - left_ext
	var off_y := float(canvas.y - used.size.y)      # 内容底边贴画布底边

	var at := AtlasTexture.new()
	at.atlas = meta["tex"]
	at.region = Rect2(used.position.x, used.position.y, used.size.x, used.size.y)
	at.margin = Rect2(off_x, off_y,
		float(canvas.x) - float(used.size.x), float(canvas.y) - float(used.size.y))
	at.filter_clip = false
	return at


## 复制一段动画到新名字（缺失动画的回退）
static func _alias_animation(sf: SpriteFrames, src: String, dst: String) -> void:
	if not sf.has_animation(src) or sf.has_animation(dst):
		return
	sf.add_animation(dst)
	sf.set_animation_speed(dst, ANIM_FPS.get(dst, sf.get_animation_speed(src)))
	sf.set_animation_loop(dst, ANIM_LOOP.get(dst, true))
	for i in range(sf.get_frame_count(src)):
		sf.add_frame(dst, sf.get_frame_texture(src, i), sf.get_frame_duration(src, i))
