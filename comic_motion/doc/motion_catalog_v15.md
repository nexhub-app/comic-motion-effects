# 动效目录 v1.5 —— 动作动效 + 效果区域 + 内容感知量调节 + AI 显著性侧车

> 承接 `motion_catalog_v13.md`（§一–§六 v1.3 存档、§七 v1.4 现行口径）。
> 本文件记录 **v1.5** 的目录增量。默认配置的序列化形状与
> configHash 一字未动——全部新能力 opt-in；新增效果不进默认效果集。
>
> 硬承诺（全部实测）：合成缓存零输出变化（on/off 双实例逐字节对照 +
> 全量字节契约测试群）；动作四件套窗口包络两端归零 ⇒ 循环无缝（u=0 与
> u=1 逐字节一致，有测试）；legacy 档新效果整体跳过。

## §八、v1.5 动作动效四件套

| # | 效果 | 类别 | 触发场景 | 预期观感 | 作用 | 参数（默认） |
|---|---|---|---|---|---|---|
| 1 | slashFlash 刀光斜闪 | 动作 | 拔刀、斩击、快门一闪 | 斜向高斯亮带短窗口扫过全屏，出手猛、收束快 | 冲击强调 | flashes 2 / windowFrac 0.16 / angleDeg 35 / widthPx 30 / intensity 0.8 / color ffffff |
| 2 | sparkBurst 火花四溅 | 动作 | 拳脚命中、金属碰撞、魔法触发 | 自焦点放射的短促火花，减速推进、env² 快速衰减 | 冲击强调（焦点） | bursts 2 / sparks 14 / windowFrac 0.28 / speedFrac 0.30 / sizePx 1.8 / opacity 0.9 / color ffd27a / focal 0.5×0.5 |
| 3 | impactDust 冲击尘雾 | 动作 | 落地、重物砸下、爆炸余波 | 自焦点外扩的一圈柔和尘团，越远越大越淡 | 重量感（焦点） | pulses 1 / puffs 10 / innerFrac 0.04 / outerFrac 0.30 / sizePx 14 / opacity 0.35 / color c9bfae / focal 0.5×0.55 |
| 4 | windStreak 风线 | 氛围/动作 | 户外、疾行、气息流动 | 横贯画面的细长气流线，泳道错峰出发 | 环境动感 | count 10 / windowFrac 0.5 / cycles 1 / swayCycles 1 / swayPx 8 / lengthFrac 0.25 / thicknessPx 1.4 / opacity 0.30 / color ffffff / angleDeg 0 |

### 与既有效果的分工（避免重复感）

- `slashFlash` vs `lightSweep`：扫光是慢速的 showcase 光带（1 循环 1 次、
  宽σ、柔）；刀光是短窗口的高频一闪（多道、窄σ、快）。
- `sparkBurst` vs `speedLines`：速度线是持续存在的放射集中线（角色的动势）；
  火花是从焦点爆出的离散粒子（一次撞击）。
- `impactDust` vs `impactRings`：波环是解析距离场**硬边环**（漫画描边感）；
  尘雾是软粒子盘（物理重量感）。同开时「环 + 尘」正是重击的完整语言。
- `windStreak` vs `speedLines`：风线是场景里的风（环境、水平、细）；速度线
  是画格的动势（放射、集中、粗）。

### 焦点与落位（精确识别联动）

- `sparkBurst` / `impactDust` 的焦点吃 contentAware 锚点：contentAware 开且
  调用方未显式 pin `focalX/focalY` 时自动取权重最高锚点（Task 2.1 同语义）。
- `windStreak` 的泳道走内容感知播种管线：activity 加权（R5/R6）+
  `effectRegions` ROI + panelAware 分格约束（R7/R8/R9）全部生效。
- 窗口式设计（meteors/闪电同族）：第 k 道只在 `(cycles·u + k/n)%1 <
  windowFrac` 时可见，包络 `sin(π·local)` 两端归零 ⇒ 无缝循环，且多数
  时刻画面安静（偶发不是背景噪声）。
- 全部只在 standard+ 档渲染；legacy 档整体跳过（handMotion 同款裁决习语）。

## §九、效果区域 effectRegions

`EffectConfig.effectRegions: {效果名: RegionParams}`——把该效果限制在画布
的一个归一化矩形内（`x/y/w/h` ∈ [0,1]，结构性 fail-fast）。语义：**限制**，
不是「移过去」；粒子的随机流、无缝循环、确定性都不受影响（RNG 消费序列
与无区域路径一致）。

- 覆盖范围（MVP）：全部播种粒子族（rain / snow / sakura / fireflies / fog /
  embers / bubbles / leaves / meteors / ambient / windStreak）。ROI 与
  panelAware 的格矩形取交集——「只在某一格的下半部分下雨」是合法表达。
- 不消费：整帧变换类（parallax/breathing/…）与自绘类（flame/smoke/
  screenTone/focusLines/…）配了不生效（文档明示，不做静默半帧裁剪）。
- 与 AI 的关系：ROI 是引擎侧的通用承载——外部 AI（或用户）识别出「该动
  的部位」后以归一化矩形下发即可。

## §十、autoCurate 内容感知量调节

`EffectConfig.autoCurate`（默认 false）：按页面平均活动度（AnchorMap 的
构造期统计）缩放全部播种粒子族的总量——

| 页面 | 平均活动度 | 行为 |
|---|---|---|
| 近空白（对话页/扉页/过渡页） | < 0.02 | 叠加粒子整体跳过 |
| 静页 | 0.02 ~ 0.12 | count × (mean/0.12)，下限 0.3 |
| 忙页（动作页/群像页） | ≥ 0.12 | 满配（与关闭状态产出一致） |

判定只在合成器构造期做一次：确定性、不影响无缝循环；contentAware=false
时本开关不生效。这是「精确识别**需要**动效的图片」的引擎侧落地：该安静的
页安静，该动的页动。

## §十一、AI 显著性侧车 anchors.json

外部 AI（显著性模型 / 人物检测 / 页面理解）与引擎之间的注入接口，与
`part_motion.json` 同族（运行期输入、不进 configHash、digest 单独记账）：

```json
{
  "version": 1,
  "anchors": [ {"x": 0.32, "y": 0.41, "weight": 0.93} ],
  "subjectBox": {"x": 0.10, "y": 0.20, "w": 0.50, "h": 0.60},
  "activity": {"width": 64, "height": 80, "values": [/* 行主序，绝对口径 */]}
}
```

- 消费：`anchors.first`（权重最高）驱动焦点类效果（focusLines /
  impactRings / sparkBurst / impactDust）；activity 网格驱动粒子密度加权；
  subjectBox 进 AnchorMap 供嵌入方消费。
- 通道：`MotionPipeline(anchors: '<json 文本>')`、CLI `--anchors <path>`
  （仅 process）、HTTP `anchorsBase64`。解析器永不抛（坏输入降级 null spec
  + warning）。指纹 `anchorsDigest` 进产物目录名与结果 JSON——「同图同
  配置、只换侧车」不会命中旧缓存。
- 优先级：anchors 侧车 > `SaliencyEstimator` 接口注入 > 内置启发式
  （`SaliencyAnalyzer`）。三者的取舍与外部 ML 适配指南见
  `doc/external-depth.md`（同族先例）与 `lib/src/anchor_sidecar.dart` 契约注释。

## §十二、性能与资源

- **静态层栈合成缓存**：效果集不含层变换效果时，首帧缓存「底图 + 层栈」
  合成结果，此后每帧整块拷贝、只重画叠加效果。实测 640×800×3 层 4 效果
  96 帧：5056ms → 707ms（7.15×）；产物逐字节不变（缓存臂与非缓存臂共用
  同一段绘制代码）。每个合成器实例多持 1 份全画布 RGBA，被 worker 内存
  模型的 1.5 安全系数吸收。
- 组合建议：overlay-only 配置（如 `rain+snow+fog`）+ `encoding.diffMode:
  'rect'`（GIF）/ APNG——渲染与体积两头省。
- 新效果的 preview 资产（`doc/previews/<demo>/`，W2 单一真相源
  `tool/generate_showcase.dart`）待下一轮补录；`kEffectPreviewRefs` 尚未
  为四效果建行。
