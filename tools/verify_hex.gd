extends SceneTree
## 一次性验证脚本：确认 HexCoord 在真实 GDScript 下的行为与 Python 验算一致。
## 用法：godot --headless --path E:/GameDemo -s res://tools/verify_hex.gd

func _initialize() -> void:
	var fail := 0

	# ---- 1. 7×7 全格 roundtrip
	var bad_rt := 0
	for col in range(1, 8):
		for row in range(1, 8):
			var cu := HexCoord.offset_to_cube(col, row)
			if cu.x + cu.y + cu.z != 0:
				print("FAIL sum!=0 at (%d,%d) -> %s" % [col, row, cu])
				bad_rt += 1
			var rt := HexCoord.cube_to_offset(cu)
			if rt != Vector2i(col, row):
				print("FAIL roundtrip (%d,%d) -> %s -> %s" % [col, row, cu, rt])
				bad_rt += 1
	print("1) 7x7 roundtrip 失败数: %d" % bad_rt)
	fail += bad_rt

	# ---- 2. 负数区间 roundtrip（GDScript 截断除法的雷区）
	var bad_neg := 0
	for col in range(-3, 12):
		for row in range(-3, 12):
			var cu := HexCoord.offset_to_cube(col, row)
			if cu.x + cu.y + cu.z != 0:
				bad_neg += 1
			if HexCoord.cube_to_offset(cu) != Vector2i(col, row):
				bad_neg += 1
	print("2) 负数区间 [-3,11] roundtrip 失败数: %d" % bad_neg)
	fail += bad_neg

	# ---- 3. DIRS 距离必须全为 1
	var d_ok := true
	for d in HexCoord.DIRS:
		if HexCoord.distance(Vector3i.ZERO, d) != 1:
			d_ok = false
	print("3) DIRS 全为距离1: %s" % d_ok)
	if not d_ok:
		fail += 1

	# ---- 4. rotate 6 步闭合 + 保 sum0 + 方向集封闭
	var r_ok := true
	for d in HexCoord.DIRS:
		if HexCoord.rotate(d, 6) != d:
			r_ok = false
		for s in range(6):
			var v := HexCoord.rotate(d, s)
			if v.x + v.y + v.z != 0:
				r_ok = false
			if not HexCoord.DIRS.has(v):
				r_ok = false
	print("4) rotate 6步闭合+sum0+方向集封闭: %s" % r_ok)
	if not r_ok:
		fail += 1

	# ---- 5. H1：§8.2.4 出生表 —— facing=2 时 M/L 必须朝上且在界内
	var anchor := HexCoord.offset_to_cube(4, 1)
	var foot_m: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, -1, 0), Vector3i(1, 0, -1)]
	var foot_l: Array[Vector3i] = [
		Vector3i(0, 0, 0), Vector3i(1, -1, 0), Vector3i(1, 0, -1),
		Vector3i(2, -2, 0), Vector3i(2, -1, -1), Vector3i(2, 0, -2),
	]
	for pair in [["M", foot_m], ["L", foot_l]]:
		var label: String = pair[0]
		var foot: Array = pair[1]
		var cells: Array[Vector2i] = []
		var max_row := 0
		var all_in := true
		for c in foot:
			var o := HexCoord.cube_to_offset(anchor + HexCoord.rotate(c, 2))
			cells.append(o)
			max_row = maxi(max_row, o.y)
			if o.x < 1 or o.x > 7 or o.y < 1 or o.y > 7:
				all_in = false
		var upward := max_row > 1
		print("5) %s @ (4,1) facing=2 占格 %s  朝上=%s 界内=%s" % [label, cells, upward, all_in])
		if not upward or not all_in:
			fail += 1

	# ---- 6. H1：facing_dir 必须落在 footprint 尖端侧
	var fd_ok := true
	for f in range(6):
		var a := HexCoord.offset_to_cube(4, 4)
		var occupied: Array[Vector3i] = []
		for c in foot_m:
			occupied.append(a + HexCoord.rotate(c, f))
		var fd := a + HexCoord.facing_dir(f)
		var hit := occupied.has(fd)
		if not hit:
			fd_ok = false
		print("   facing=%d 占格尖端含 facing_dir: %s" % [f, hit])
	print("6) facing_dir 全朝向落在尖端侧: %s" % fd_ok)
	if not fd_ok:
		fail += 1

	# ---- 7. MAP_Y_FLIP 必须偶数（否则 odd-r 奇偶翻转）
	var flip_even := (HexCoord.MAP_Y_FLIP % 2) == 0
	print("7) MAP_Y_FLIP 是偶数: %s (=%d)" % [flip_even, HexCoord.MAP_Y_FLIP])
	if not flip_even:
		fail += 1
	var parity_ok := true
	for col in range(1, 8):
		for row in range(1, 8):
			var m := HexCoord.offset_to_map(col, row)
			if HexCoord.map_to_offset(m) != Vector2i(col, row):
				parity_ok = false
			if (m.y & 1) != (row & 1):
				parity_ok = false
	print("   map 往返 + 奇偶性保持: %s" % parity_ok)
	if not parity_ok:
		fail += 1

	# ---- 8. rear_dir_index == (3-facing)%6
	var rear_ok := true
	for f in range(6):
		if HexCoord.rear_dir_index(f) != posmod(3 - f, 6):
			rear_ok = false
		if HexCoord.backstab_dirs(f).size() != K.BACKSTAB_REAR_OFFSETS.size():
			rear_ok = false
	print("8) rear_dir_index 与背击方向数: %s" % rear_ok)
	if not rear_ok:
		fail += 1

	print("")
	print("========== 总失败数: %d ==========" % fail)
	quit(0 if fail == 0 else 1)
