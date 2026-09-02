# Hex Spire（暂名）— 灰盒可玩 Demo

单人肉鸽 + 六边形战棋 + 卡牌构筑。主题「东方怪谈 × 现代城市」。

**当前状态：P2-A 完成** — 灰盒可玩，战斗已有真实挑战（Boss 局会输）。

## 怎么运行

```bash
# 图形界面（能玩）
"E:/Godot_v4.7.2/Godot_v4.7.2-stable_win64.exe" --path .
```

或直接用编辑器打开 `project.godot` 后按 F5。

**操作**：点卡牌选中 → 点战场格子打出 → 右键取消 → 空格结束回合
**F1** 切换坐标调试层。右上角可切换英雄 / 地形 / 怪物组，改完点【重开】。

## 战斗平衡（P2-A 实测）

| 配置 | 胜率 | 掉血率 |
|---|---|---|
| 骑士 vs Boss（open_hall/enc_04） | **0%** | 100% |
| 巨人 vs Boss（open_hall/enc_04） | **0%** | 100% |
| 巨人 vs Boss（narrow_pass） | **38%** | 90% |
| 巨人 vs 精英（spike_cell/enc_03） | 100% | 45% |
| 骑士 vs 杂兵（open_hall/enc_02） | 100% | 22% |

16 格矩阵中 **8 格进入张力区**（胜率 40–90% 或掉血率 ≥40%）。

> ⚠️ **「张力」的判据不能只看胜率。** 贪心 AI 有完美信息、从不失误，
> 它的胜率衡量的是"数值上限能不能赢"而非"人类玩起来难不难"。
> 巨人 vs Boss 胜率曾是 100% 但掉血 80% —— 对 AI 是稳赢，对人类是"稍微失误就死"。
> 所以 `verify_balance.gd` 同时看掉血率。

**两个英雄的定位已分化**（§4.2）：骑士 = 坦克（厚守备、只 2 张位移卡）；
巨人 = 地形型（HP 150、M 体型堵路、范围+推拉）。

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

# 平衡矩阵（16 格，含张力判据与超时哨兵）
"$GODOT" --headless --path . -s res://tools/verify_balance.gd -- --battles=8

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

## 分辨率适配

窗口默认开 **1280×720**，可自由拉伸/最大化，最小 960×540。

- `stretch/mode = canvas_items` + `aspect = keep` → 整个画布**等比缩放**，非 16:9 时两侧留黑边
- UI 全部用**锚点 + offset**，不用绝对像素坐标
- 战场相机按**实际视口尺寸**算缩放，窗口变化时自动重新居中（监听 `size_changed`）

已实测 1024×576 / 1280×720 / 1440×900 三档，UI 全部完整可见。

多分辨率截图对比：
```bash
"E:/Godot_v4.7.2/Godot_v4.7.2-stable_win64.exe" --path . --resolution 1024x576 -- --shot --shot-name=1024
```

## 四个踩过的坑（改代码前必读）

1. **`DIRS[facing]` 不是朝向向量**（陷阱 H1）。`rotate()` 使索引递减，取朝向必须用 `HexCoord.facing_dir()`。已用 §8.2.4 出生表交叉验证：§8.1 原文的 rotate 公式是对的，**不要改**。

2. **「能否通过狭道」是寻路问题，不是 footprint 问题**。我用静态几何试了 4 种判据全部失败（详见 `tools/verify_footprint.gd` 的注释）。通过性必须在 `(anchor, facing)` 状态图上搜索。

3. **`MAP_Y_FLIP` 必须是偶数**。业务 row 1 在下、Godot map y 向下增长，翻转常数取奇数会让 odd-r 的奇偶性翻转，网格被剪切错位且**单看一格完全正常**，极难发现。

4. **UI 不要用绝对像素坐标**。第一版把按钮写死在 `x=1660`、手牌在 `y=880`，配上 `aspect="expand"`（视口不缩放、只露出更多/更少内容），结果小于 1080p 时 UI 全部跑到画面外。改用锚点 + `aspect="keep"`。

## 目录

严格照策划案 §14.1，未自创结构。核心逻辑在 `src/core/`（纯逻辑、零 Node 依赖、可无渲染跑完），表现层在 `src/scenes/`（只订阅事件、不驱动逻辑）。

## 后续阶段

**已知未解决**：`knight + narrow_pass + enc_03` 会 100% 超时。石傀(M) 能过 2 格门但
会陷入局部最优僵局，加上玩家 3 张位移卡几乎总能躲开"可躲"意图 → 双方都打不到对方。
数值调不动它，需要下面的 P2-B 或替代胜利条件。已作为回归哨兵保留在矩阵里。

- **P2-B 状态效果系统**（§8.9 的 10 种状态）— 眩晕/定身让「打断敌人意图」成为可能，
  这是「硬但公平」的核心应对手段，也能顺带修掉《点燃》《巨岩之躯》两张废卡
  （burn/chill 目前是 no-op）
- **P2-C 敌人 AI 战术层** — 躲 hazard、保持射程、绕后背击、残血撤退、支持多目标
- **替代胜利条件**（§8.10 `win_condition`）— "存活 N 回合" / "到达出口格"，
  能让 bottleneck 这类地图成立
- **P4 符文（D6）** — 埋点齐全但 `listener_count()` 恒 0。它让玩家更强，
  所以放在平衡稳定之后
- P6 盲探地图 + 腐蚀度（`corruption` 参数已存在但恒为 0）

## 文档

- `docs/00_系统策划案.md` v0.3 — 系统真相来源，玩法规则一律以它为准
- `docs/01_美术高概念.md` v0.2 — 视觉风格、色板、主题色系统
