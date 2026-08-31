class_name K
## 全局常量与可调参数的唯一定义处。
##
## 纪律：数值不散落在逻辑里。想调手感 → 改这里 → 重跑 battle_sim。
## 策划案 §4.4 的所有 K_* 占位常量都落在此处。

# ------------------------------------------------------------------ 伤害管线

## 伤害下限。
## ⚠️ 已确认偏离策划案 §4.4 字面顺序：下限卡在【扣格挡之前】。
##   按字面（下限在格挡之后）会让格挡永远无法完全吸收一次攻击 ——
##   Block=999 也要掉 K_MIN 血，骑士的「格挡不清空」被动因此失去意义。
##   「保证永远能破防」针对的是 DEF 软曲线，不是 Block。
const K_MIN_DAMAGE := 1

## 防御减伤软上限：减伤率 = DEF / (DEF + K_DEF_SOFTCAP)
## DEF=30 时减伤 37.5%，DEF=100 时 66.7% —— 递减曲线，防止后期免伤
const K_DEF_SOFTCAP := 50.0

## 暴击基础倍率与 LUK 加成（§4.3：CRIT 管频率，LUK 管倍率）
const K_CRIT_BASE_MULT := 0.5
const K_LUK_TO_CRIT_DMG := 0.02

## 闪避：AGI 的次要作用之一
const K_AGI_TO_DODGE := 0.005
const K_DODGE_CAP := 0.30

## 移动卡额外位移：每 K_AGI_PER_STEP 点 AGI 多走 1 格
const K_AGI_PER_STEP := 8

# ------------------------------------------------------------------ 战斗规则

const HAND_LIMIT := 10
const BOARD_COLS := 7
const BOARD_ROWS := 7
const HERO_SPAWN_COL := 4
const HERO_SPAWN_ROW := 1
const HERO_SPAWN_FACING := 2  ## §8.2.4：朝上

## 敌人生成区（§8.8：我方在下、敌方在上）
const ENEMY_SPAWN_ROW_MIN := 5
const ENEMY_SPAWN_ROW_MAX := 7
const ENEMY_SPAWN_MIN_DIST := 2

# ------------------------------------------------------------------ 背击

## 背击后弧：相对【正后方索引】的偏移。
## §8.2.3 只说"背面 2 个方向"，未指明是哪两个。三个候选（facing=2 为例，前方 (4,5)）：
##   [-1, 0] → (5,4) (5,3)   正后方 + 一侧
##   [ 0, 1] → (5,3) (4,3)   正后方 + 另一侧
##   [-1, 1] → (5,4) (4,3)   两侧后弧（不含正后方）
##   [-1,0,1] → 三方向对称后弧
## P2 试玩后定。改这一行即可，逻辑不散落在 DamageCalculator 里。
const BACKSTAB_REAR_OFFSETS: Array[int] = [0, 1]

## 背击伤害乘区（§8.2.3：加成 + 无法被闪避）
const BACKSTAB_MULT := 0.5

# ------------------------------------------------------------------ 安全闸（R7）

## 符文触发递归深度上限。超限 → 写 rule_violations 并停止分发，【绝不 crash】。
## battle_sim 靠这条把死循环变成可统计数据。
const MAX_TRIGGER_DEPTH := 10

## 单次 emit 内的触发总数上限。
## 兜住"A 触发 B、B 触发 A"这种深度=2 但宽度爆炸的组合
## （策划案 R7 只提了深度，这条是补的）。
const MAX_TRIGGERS_PER_EMIT := 64

## 单次 resolve_all 的动作总数上限。死循环硬闸。
const MAX_ACTIONS_PER_RESOLVE := 2000

## battle_sim 单场回合上限，超过计入 timeout
const MAX_ROUNDS_PER_BATTLE := 50

# ------------------------------------------------------------------ 表现层

## 事件播放间隔（秒）。设为 0 = 一键跳过动画（§13.2）
const EVENT_PLAYBACK_INTERVAL := 0.12

## Tile 尺寸（美术文档 §9.1：尖顶六边形，高 = 宽 × 2/√3 = 147.8 → 148）
const TILE_W := 128
const TILE_H := 148
