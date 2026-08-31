# Hex Spire（暂名）— 灰盒可玩 Demo

单人肉鸽 + 六边形战棋 + 卡牌构筑。主题「东方怪谈 × 现代城市」。

**当前状态：P1 完成** — 零美术资产的灰盒版本，可打完一场完整战斗。

## 怎么运行

```bash
# 图形界面（能玩）
"E:/Godot_v4.7.2/Godot_v4.7.2-stable_win64.exe" --path .
```

或直接用编辑器打开 `project.godot` 后按 F5。

**操作**：点卡牌选中 → 点战场格子打出 → 右键取消 → 空格结束回合
**F1** 切换坐标调试层。右上角可切换英雄 / 地形 / 怪物组，改完点【重开】。

## 验证（全部 headless，退出码即结论）

```bash
GODOT="E:/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe"   # 注意是 _console 版才有 stdout

# 架构纪律静态检查（§12.1）
"$GODOT" --headless --path . -s res://tools/check_discipline.gd

# 坐标系（8 项）
"$GODOT" --headless --path . -s res://tools/verify_hex.gd

# 体型占位 R9（3528 组 can_place 与独立参考实现比对）
"$GODOT" --headless --path . -s res://tools/verify_footprint.gd

# 伤害管线（6 项，含 §6.5 符文顺序与 R2）
"$GODOT" --headless --path . -s res://tools/verify_damage.gd

# 寻路与体型闸门（5 项）
"$GODOT" --headless --path . -s res://tools/verify_pathfinding.gd

# 批量模拟（R1' 重复率 / R7 稳定性 / 确定性）
"$GODOT" --headless --path . -s res://tools/battle_sim.gd -- \
    --battles=50 --seed=1 --verify-determinism

# 单场逐回合诊断
"$GODOT" --headless --path . -s res://tools/debug_battle.gd -- \
    --hero=giant --layout=narrow_pass --enc=enc_03

# 无人值守截图（验证画面）
"E:/Godot_v4.7.2/Godot_v4.7.2-stable_win64.exe" --path . -- --shot
```

⚠️ 新增 `class_name` 后需重建类缓存，否则 headless 脚本报「Identifier not declared」：

```bash
rm -rf .godot
"$GODOT" --headless --path . --editor --quit-after 4000
```

（纯 `--import` 不够，必须走 `--editor`）

## 已验证的关键结论

| 项 | 结论 |
|---|---|
| **格挡** | Block=999 时打生命 0 —— 已确认偏离 §4.4 字面顺序，下限卡在扣格挡之前 |
| **符文顺序（§6.5）** | `[锐化,倍化]=21` vs `[倍化,锐化]=19` —— D6 的「免费深度」成立 |
| **R2 强数值** | ATK 从 10 拉到 200，7 张卡的强度排序完全不变 |
| **R1' 一致性** | 出牌序列重复率 0.000（阈值 ≤0.45） |
| **R7 稳定性** | 50 场零违规、零溢出、零超时 |
| **纪律 5 确定性** | 同 seed 两次运行 action_log 哈希逐位一致 |
| **体型闸门** | 门宽 1格→只有 S 过 / 2格→S,M 过 / 3格→全过（用寻路判定，非静态几何） |

## 三个踩过的坑（改代码前必读）

1. **`DIRS[facing]` 不是朝向向量**（陷阱 H1）。`rotate()` 使索引递减，取朝向必须用 `HexCoord.facing_dir()`。已用 §8.2.4 出生表交叉验证：§8.1 原文的 rotate 公式是对的，**不要改**。

2. **「能否通过狭道」是寻路问题，不是 footprint 问题**。我用静态几何试了 4 种判据全部失败（详见 `tools/verify_footprint.gd` 的注释）。通过性必须在 `(anchor, facing)` 状态图上搜索。

3. **`MAP_Y_FLIP` 必须是偶数**。业务 row 1 在下、Godot map y 向下增长，翻转常数取奇数会让 odd-r 的奇偶性翻转，网格被剪切错位且**单看一格完全正常**，极难发现。

## 目录

严格照策划案 §14.1，未自创结构。核心逻辑在 `src/core/`（纯逻辑、零 Node 依赖、可无渲染跑完），表现层在 `src/scenes/`（只订阅事件、不驱动逻辑）。

## 后续阶段

- **P2** 状态系统 / 意图可躲追踪的完整表现 / Undo / 伤害预览细化
- **P3** 体型上场：巨人可选、M/L 敌人、footprint 落点预览
- **P4** 符文 6 槽有序（D6）+ 符文实验室 UI
- **P5** battle_sim 扩到 10 万场（M0 判据③）
- **P6** 盲探地图 + 腐蚀度（D4）

## 文档

- `docs/00_系统策划案.md` v0.3 — 系统真相来源，玩法规则一律以它为准
- `docs/01_美术高概念.md` v0.1 — 视觉规范、色板、tile 规格
