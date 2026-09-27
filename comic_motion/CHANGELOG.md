# Changelog

本项目版本记录。版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)，`pubspec.yaml`、`lib/src/version.dart` 与 `dart run bin/comic_motion.dart --version` 使用同一常量。

## 1.3.0 — 2026-09-19

新增 11 个动效与一条情绪编排层，像素质量整体上一档；性能靠并行与批量化买回来，经典路径逐字节承诺不变。

### ⚠ BREAKING CHANGE

- `RgbaImage.data` 由「逐像素可写的嵌套列表」改为扁平 **`Uint8List`**（RGBA 4 字节/像素，`width*height*4` 定长）。直接读取 `.data` 的嵌入方需要改成下标访问；新增 `RgbaImage.fromBytes(...)` 可零拷贝包住既有栅格。
- 该改动对 CLI / HTTP API / 预设使用者的输出**没有影响**，只影响把 `comic_motion` 当库嵌入并自己摸像素的代码。

### 新增动效（11）

- **漫画动势语言**：`focusLines` 集中线（楔形条向焦点收束，`mode: black|white|both`）、`screenTone` 网点（斜向网点阵列漂移，`mode: dot|line|cross`）、`impactRings` 冲击波环（同心环外扩收薄，`mode: ring|shock`）、`brushStreak` 笔触速度带（带飞白断口的粗笔触）、`mangaShake` 画面震动（衰减式抖动 + 微量旋转）。
- **自然氛围**：`flame` 火焰（多火舌扭动明灭）、`smoke` 青烟（上升扩散 + 湍流）、`bubbles` 气泡（蛇行上浮、速度按大小分层）、`leaves` 落叶（翻面变窄露叶脉，`palette: autumn|spring|summer`）、`meteors` 流星（窗口式划过）。
- **节奏编排**：`moodScript` 情绪包络。不绘制任何像素，只把一条曲线乘进既有振幅类参数（`motion`/`particles`/`exposure`/`warmth`/`vignette`）。`mood: tension|calm|eerie|burst`，`strength: 0` 时因子严格退化为恒等。

### 新增能力

- **渲染档位** `quality.tier = legacy | standard | rich`（默认 `legacy`）。standard 起启用覆盖式抗锯齿光栅、Catmull–Rom / 面积平均重采样、光效 screen 混合、深度图双线性上采样与掩码羽化、层边缘色外扩（`edgeStretchPx`）、GIF 量化 LUT + 首/中/末三帧调色板采样，以及可选 `ditherMode: sierra`。**已知偏差**：`rich` 目前与 `standard` 渲染结果完全相同——`RenderTier.supersample` 与 `QualityParams.mipLevels` 已定义但尚无消费方，降采样走的是 standard 的面积平均路径；两项配置都能序列化与读回，等后续接入超采样时再启用。
- **并行帧渲染** `MotionPipeline(config, parallel: n)` 与 `--parallel`（`auto`/正整数，`1`=串行）。只影响耗时，输出字节与串行逐字节一致（bench 的 1/2/4/8 扫描会校验这一点）。两种失败模式分开处理：起池失败（isolate 资源不足）→ 回落串行并在结果/台账里置 `parallelFallback: true`；worker 运行中抛异常或 isolate 意外退出 → 整单失败，错误码 `E_WORKER_CRASH`，不静默吞掉。
- **配置回落提示** `PipelineResult.warnings`：目前只有 `moodScript` 的未知 `mood` 会回落 `calm` 并写提示。效果参数越界在取样处静默 `clamp`，`fps/layerCount` 这类结构性整型不夹紧（越界按各自通路的退化行为出图，不报错也不提示）。CLI 打到 stderr、HTTP 结果与 JSONL 台账各带一份；`warnings` 属执行期属性，不进 `configHash`。
- 预设与图鉴扩到 38 份预设 / 37 组演示；`presets/*.json` 由 `tool/generate_showcase.dart` 单一真相源生成。

### 性能

同机 18 核、JIT 预热后二跑，`dart run tool/bench.dart`（详见 `build/bench/bench_report.json`）：

| 场景 | v1.2 | v1.3（parallel=8） | 红线 |
|---|---|---|---|
| draft_480p | 652 ms | **233 ms** | ≤450 ms ✅ |
| typical_1080p | 11 244 ms | **2 248 ms** | ≤5 000 ms ✅ |
| preview_1600 | 15 756 ms | **3 491 ms** | ≤7 000 ms ✅ |
| rich_1080p（19 效全开，legacy 档） | 10 400 ms | **2 702 ms** | 不比基线慢 ✅ |
| standard_1080p（3 效，standard 档） | 新增 | **4 262 ms** | — |
| rich_tier_1080p（19 效，rich 档 + sierra） | 新增 | **4 704 ms** | — |
| v13_full_1080p（32 效 + standard 档） | 新增 | **5 201 ms** | ≤9 000 ms ✅ |
| peak RSS（parallel=8 / parallel=1） | 671 MB | **628 MB / 628 MB** | ≤1 150 / ≤780 MB ✅ |

并行度扫描（standard 档 1080p/96 帧）：`1 → 16 666 ms`、`2 → 9 451 ms`、`4 → 6 075 ms`、`8 → 4 770 ms`，四次 GIF 字节完全一致。spec §5 红线无一项超标，因此 §6 的质量回退顺序（Catmull-Rom 降双线性等）**未被触发**。

### 修正（文档反查代码时发现，均有用例锁定）

- **配置文件里 `quality` 段缺省 `dither` 时不再静默开抖动**：`QualityParams` 构造默认 `false`，但 `fromJson` 的兜底仍是 v1.2 时代的 `?? true`——于是手写 `{"quality":{"tier":"standard"}}`（HTTP `config` 与 `--config` 都走这条路）会拿到抖动开启的图，与 `--quality standard` 的 CLI 路径不同哈希。现两处默认统一为 `false`。由 `presets/*.json` 生成的文件不受影响（`quality` 段一旦写出就总带 `dither` 键）。
- **配置里的未知效果名改为报 `ConfigException`**：`effects: ["raiin"]` 原先静默 `orElse` 成 `parallax`（与 README 的错误表、spec §兼容性条、CLI 的 `--effects` 校验三方都矛盾）。现 CLI 与配置解析共用 `effectKindFromName()`，未知名与非字符串元素一律报错。
- **`--dither` 的帮助文本**原写「默认开」，实际默认关；已改。

### 兼容性

- `EffectConfig().configHash` 仍为 `-477687d5e8bded5f`，classic 预设仍为 `2e1a45e07164337e`。
- 11 个新参数段与 `moodScript`、`quality` 全部**条件序列化**（仅当对应效果启用 / 值非默认时写入），未启用时 JSON 与指纹不变。
- `presets/classic.json`（`quality.tier` 缺省即 legacy）2026-09-19 复跑 10 张样图、`parallel=4`：输出 GIF 的 SHA256 与 2026-09-14 采集的基线（`build/rollback_baseline/hashes.txt`，v1.2 轮冻结件；该轮文档当时已记录其与 v1.0.0 输出逐字节一致）**10/10 一致**（明细 `build/rollback_v13_drill/hashes.txt`）。同一次演练顺带复核了「并行 = 串行」。

### 测试

124 例（v1.2 为 30 例）：新增每个动效的压暗/提亮画像、参数单调性、`opacity=0` 空操作、确定性、整循环无缝、`reducedMotion` 静帧、legacy↔standard 光栅差异、条件序列化与 JSON 往返、包络恒正与首尾闭合、并行=串行字节一致，以及 `quality` 段 `dither` 缺省值与构造默认一致（含指纹相等）、配置里的未知效果名抛 `ConfigException` 两条契约用例。

## 1.2.0 — 2026-09-15

- 新增 8 个动效：`fog` 流雾、`embers` 余烬、`lightning` 闪电、`toneShift` 色调呼吸、`vignette` 暗角呼吸、`starlight` 星光闪烁、`slowPush` 缓慢推镜、`shimmer` 波光。
- 新增 `QualityParams{dither}`：Floyd–Steinberg 误差扩散抖动，减轻 GIF 256 色渐变色带；默认关闭以保住逐字节回滚承诺。
- 新增组合演示 `combo_storm_night`、`combo_campfire` 与 `dither_compare_forest` 画质对比卡；效果图鉴上线。
- 全部新效果 opt-in，不进默认 `effects`；配置指纹与 v1.0.0 一致。

## 1.1.0 — 2026-09-14

- 新增 8 个动效：`rain`、`snow`、`sakura`、`fireflies`、`godRays`、`speedLines`、`impactFlash`、`heartbeat`。
- 新增 `--effects` 组合开关、`presets/` 预设体系与 `classic.json` 一键回滚。
- 动效统一按 `u = (t/duration) % 1` 的整数倍周期参数化，首尾帧逐字节一致（无缝循环）。

## 1.0.0 — 2026-09-13

- 基线：深度分层拆解 + 2.5D 视差 + 呼吸缩放 + 氛围粒子（`parallax`/`breathing`/`ambient`，另有 `lightSweep`/`dust`）。
- CLI（`process`/`batch`/`serve`/`job`）、shelf HTTP API、JSONL 台账、流式 GIF 编码、确定性种子与 `configHash`。
