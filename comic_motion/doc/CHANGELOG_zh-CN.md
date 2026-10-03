# Changelog

本项目版本记录。版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)，`pubspec.yaml`、`lib/src/version.dart` 与 `dart run bin/comic_motion.dart --version` 使用同一常量。

## 1.4.0（2026-10-03）

内容感知落位 + 硬派张力。**本版带两个刻意的破坏性变更，均在实施前作为产品决策获批**（下面的 H1 与 H2）：JSON schema 未变、没有新增必填键、不需要迁移步骤——移动的是**默认值**与 `legacy` 的**含义**，所以显式钉住取值的配置逐字节照旧，只有未钉值的配置随之改变。

### H1——出厂默认就地改动

- `quality.tier`：`legacy` → **`standard`**。开箱输出走抗锯齿光栅原语、面积平均 / Catmull-Rom 重采样、screen 光照混合与量化 LUT。
- `parallax.amplitude`：`0.012` → **`0.030`**，并按规格 §6.1 同步抬高配套默认（`breathing.amplitude` 0.006 → 0.012、`ambient.opacity` 0.16 → 0.22、`mangaShake.amplitude` 0.009 → 0.018、`heartbeat.intensity` 0.012 → 0.020、`slowPush.pushFrac` 0.035 → 0.060）。本轮的起因是「动作效果几乎等于没有」。
- `contentAware` → **`true`**、`panelAware` → **`true`**（见落位小节；两个门各自独立回滚）。
- `quality.dither`：回到 **`false`**（R38）。误差扩散把 GIF 字节乘 2.2–2.4×，对 flat-ink + 线稿语料不划算；锐度来自 standard 档而不是抖动。`quality.ditherMode` 仍默认 `sierra`，但处于**惰性**状态——只有显式 `dither: true` 时它才决定用哪个核。
- 由于「等于默认值的键照旧省略」，默认配置的序列化形状一字未动，移动的是每份配置渲染出的字节。

### H2——`legacy` 收窄为「旧像素算法」

- `tier: legacy` 仍然冻结**绘制通路**（不做抗锯齿的光栅、双线性/最近邻重采样、纯 source-over 落墨、v1.2 量化器），仍可显式选择、能无损往返；但它**不再**承诺「与 2026-09-14 的 v1.2 基线逐字节一致」。原因是无缝循环修复重写了**两条臂共用**的时间基——整数循环周期对齐（R18）、竖向整数循环数（R19）——而层反相步进（R16）是相位常数而不是像素算法；这三项都不受档位门控。
- 因此 `presets/classic.json` 对冻结的 v1.2 摘要的演练结果是 **0/10**。这是被记录并认可的状态，不是回归；同版本内的确定性（同 seed + 同参数 ⇒ 逐字节一致）完全没有变化。
- **唯一一次 `configHash` re-baseline**（本版只此一次）：`test/engine_test.dart`、`test/polarity_test.dart`、`test/saliency_test.dart` 里钉死的绝对指纹（共 13 处字面量）按测试打印出的 actual 重新锚定。新锚点：默认配置 `-2a0679b63611bcad`、`EffectConfig(fps: 12, durationSec: 3.0, maxDimension: 640)`（即 `presets/classic.json`）`-55953db41ee98064`、`presets/legacy_v1.0.json` `-57e243b1ecfc30c`。未移动的 v1.2 legacy 金色基线（`-68ddcb969faac38c` 等）保留为「3.6 系列没碰 legacy 像素通路」的证据。
- `presets/legacy_v1.0.json`（R40）成为回滚时应取的文件：v1.0.0 的**数值** + 显式 `tier: legacy` + `dither: false` + 两个落位门显式写 `false`。它是**行为级**回滚而非字节级（R46b）。其 `durationSec` 取 `6.0` 而不是 v1.0.0 的 `3.0`——这是唯一一处故意偏离——因为整周期规则下只有 6.0 能精确表达 `parallax.periodSec 6.0`。

### 内容感知落位（P1–P2）

- 新增 `AnchorMap`（`lib/src/content/`）：显著性/活动度场、主体框、NMS 焦点锚、逐格锚点；每次渲染只算一次，贯穿管线、帧 worker 与交互帧集导出（R37）。
- 消费方：`focusLines` / `impactRings` 锚在焦点而非画布中心；粒子播点按活动度加权而非均匀随机；分格叠加绘制按格边界裁剪；落墨极性按局部亮度自适应。
- `contentAware`（逐效果锚定）与 `panelAware`（逐格分层）是两个**正交**的门，各自独立回滚。二者都按「等于默认就省略」的条件序列化习语落地，所以 `"contentAware": false` / `"panelAware": false` 能持久化并无损往返。
- 两个门的 JSON sanitize 口径（参数目录与服务端 API 文档同步）：缺键或显式 `null` = 没说过 ⇒ 落默认 `true`；只有严格等于布尔 `true` 才算开启，非 bool 值（`1`、`"yes"`）按 `false` 处理 ⇒ 落回滚臂。

### 张力（P3）

- 层反相视差（R16）：相邻景深层反向扫动，奇偶性取自 `depthRank`（F2），因此跨格稳定。
- `snapWave` 缓动（P3.3/P3.4）在 standard+ 档成形 `mangaShake`、`speedLines`、`impactRings`——「起—峰—断」：快速攻到峰值后是**硬切**，波形的负瓣被 `max(0, ·)` 截成 0，后半段保持静默，**不是**正弦，也不是「快起慢落」的长尾余韵（`impactRings` 的落墨在 ph ≳ 0.539 起恒为 0，约占整循环 44%）；legacy 臂逐字保留 `sin`。两者的形状差异由**渲染像素**的判别用例守护（`test/snap_wave_passes_test.dart`），不是只查公式。
- `periodSec` 自动对齐到整循环数（R18），竖向视差轴对齐到整数循环数（R19），使任意时长下循环都无缝，而不是尾帧跳一下。

### 预设、参数目录与文档

- `presets/` 共 42 份：40 份演示预设（单效、组合与三个演示底座）由单源生成器重发，外加 `classic.json` 与新增的 `legacy_v1.0.json` 锚点。注意分组名里的「v1.1/v1.2 代」描述的是**效果列表**的世代而不是渲染档——重发后 42 份里**只有 `legacy_v1.0.json` 写了 `tier`**，40 份整段省略 `quality`，`dither_compare_forest.json` 只写 `"dither": true`（它就是抖动演示）。`legacy_v1.0.json` 里那句 `"dither": false` 是生成器**手写**的意图表达，不是 `toJson()` 的产物（默认 false 的键按习语应当省略）；R40 的守卫读的是文件、不是重发结果。
- `param_catalog.dart`：新增 `contentAware` / `panelAware` 两行（目录是默认值的第五个锁步源，与构造默认互相守卫）；`qualityTier` 行按 H2 纠正；`strictRange` 的说明改为逐参数列出**越界后的真实行为**（原样线性放大 / 该 pass 内部自带 clamp / 三角函数周期回绕 / 枚举串回退默认），不再暗示存在通用 clamp。
- README（中英）、`comic_motion_server/docs/api.md`、`docs/deploy.md`、`doc/motion_catalog_v13.md` 同步到新默认值与收窄后的 `legacy` 口径；CLI 的 `--quality` 帮助文本不再声称逐字节复现 v1.2。

### 仅记录的更正与已知限制

- 提交 `597aefb`（"presets re-emitted … with aligned periods"）**言过其实**：预设里 `periodSec` 是有意保持 6.0 / 4.0 的，对齐发生在渲染期（R18）。历史不改写，真实语义在此说明。
- **§6.1 stale 重发守卫的盲区**（经裁决接受）：预设守卫断言 `值 >= 新默认 × 0.8`，而旧的 `breathing.amplitude` 变体 `0.010` 恰好等于一个合法新值（0.005 × 2.0 = 0.010），任何 `>= 下限` 形态都分不开两者 ⇒ 单独回退那 2 个 breathing 预设不会被拦住，整批 stale 重发仍会在其余五个键上转红。**不**把下限抬回默认值（那会让已提交的预设集体转红），也不为此改生成数据。
- **被丢弃的 saliency 扫描**（裁决 #14）：分层导出现在会付一次 saliency 扫描，而该路径丢弃其结果。作为**主干成本**记录（渲染与导出共用同一分析入口），不加旋钮。
- `rich` 仍与 `standard` 逐字节等价（预留的 `supersample` / `mipLevels` 尚无消费方）——已知偏差，未变。
- **多格页在 1600 上限下更贵，并压破两条红线**（实测，3 次 bench 的中位数）：真实两格页在出厂默认档下耗时 **8.17 s**，超 `≤7 s` 的预览红线（3 次里 2 次超）；峰值 **1033 MB**，破 `parallel=1` 的 780 MB 串行红线（≥2 worker 的 1150 MB 线仍成立）。根因是 `panelAware`（R39 起默认开）为每格保留一份层栅格，峰值内存随**格数**而不只随工作像素增长——同 `maxDimension` 下单页 647 MB、两格 1033 MB。**没有为它放宽任何阈值**。部署侧对策：传 `memoryBudgetMb`（OOM 前先降工作分辨率并写入 `warnings`）、或把 `maxDimension` 降到 1080、或多格页至少用 2 个 worker。完整前后数据见中英 README 性能章节。

测试面：393 例引擎用例 + 服务端契约用例，全绿、零 skip；`dart analyze lib tool test` 无告警。

## 1.3.1（2026-09-28）

发布导向改造（包拆分、跨平台路径、解码安全、错误码体系、fail-fast 校验、内存预算、台账可关闭）+ 运行时生命周期接口（全内存管线、取消/进度/超时、后台 isolate、并发防护、渲染参数/效果选择 API、条漫 strip 模式）。逐字节复现契约全程未破坏（legacy 档像素路径与编码字节零改动，测试护栏扩至 253+6 例）。

### 高帧率与生态扩展

- **路线图刷新与能力矩阵同步（文档）**：`doc/roadmap.md` 移除本轮已实施项（GPU 变换类 MVP / 分格感知分层 / AI 深度接口化，文首内嵌刷新记录），剩余项刷新为——shader 粒子类效果 GPU 化（`comic_motion_shaders` 二期，fragment 侧确定性哈希重建粒子轨迹）、AI 模型深度（守 `DepthEstimator` 接口注入路线，服务端 / 可选伴生包落位优先，新增 panelAware 逐格注入协同决策点）、animated WebP 备选（激活条件不变）、**多轴交互帧集进阶**（新增，交互视差路线第三轴：缩放 / 光照 / 旋转候选，独立帧层叠加避免 M³ 组合爆炸）。README（中英）能力边界更新：实时 GPU 路径已落地为 [`comic_motion_shaders`](../comic_motion_shaders) 伴生包（MVP：parallax / breathing / lightSweep / vignette 单一 uber-shader 实时渲染 `exportLayers` 分层纹理集），粒子类效果仍在路线图；flutter 包 README（中英）架构图补 shader 包分支。三包能力矩阵对齐：PageCurlView（flutter 包）、panelAware（本包）、预览资产（本包 `doc/previews/`）、shader 伴生包各有 README 段落承载。
- **AI 深度接口化（架构）**：`DepthEstimator` 改为抽象接口（`estimate(RgbaImage) → DepthMap`），内置启发式实现改名 `HeuristicDepthEstimator`（**breaking rename**，实现原样搬入、默认路径像素输出逐字节不变——测试锁定）；`MotionPipeline(depthEstimator:)` 可注入外部 ML 估算器（App 侧 tflite 等，核心包保持零原生依赖；执行期依赖不参与 configHash）。新增 `exportLayers` / `exportLayersFile`（`lib/src/layer_export.dart`）：分层栅格导出为 PNG 纹理集 + `index.json`（`kind: layers`，层 rank 与 panelAware 格边界 clip 一并记录），与管线内部分层像素级一致（RGBA 编码保留 alpha——羽化遮罩是 shader 混合必要信息，新增 `ImageIO.encodePngFrameRgba`）；产物目录 `<stem>_<contentHash8>_<configHash8>_layers/`，同时服务 shader 伴生包与外部 ML 调试。新增 `doc/external-depth.md`（外部 ML 实现指南：接口契约、tflite 适配示例、深度方向/分辨率/隔离/确定性注意项）与 `test/depth_interface_test.dart`。
- **分格感知分层（MVP 只做水平分格）**：新增 `PanelSplitter`（横向白带扫描：行近白占比 ≥0.90、亮度 ≥245 记白带行，带厚 ≥0.5% 页高为分隔带，格高 ≥6% 页高保留，检出 <2 格自动回退整页——均衡档参数经方案确认）与 `EffectConfig.panelAware`（opt-in，**条件序列化**默认 false 指纹不变）。panelAware 开启时逐格独立 DepthEstimator + LayerSplitter（层写回全图坐标、携带格内 rank 与格边界裁剪 `LayerImage.clip`），合成器 `drawLayer` 按画布坐标钳制绘制区域——**跨格串色根除**（白带行保持纯白，测试锁定）；视差倍率按格内 rank 归一（同 rank 同幅度、跨格一致）。`FrameJobSpec` 跨 isolate 携带 ranks/clips，并行与串行产物一致；单格/无白带图与关闭时逐字节等价；与 strip 模式正交（片内 panelAware 自动生效）。探针 13/13（分格检测/单格等价/不串色/确定性/strip 正交），正式用例 `test/panel_aware_test.dart`。
- **高帧率预渲染档位（核心包验证 + 文档）**：`encoding.apngDelay: 'exact'`（opt-in）——APNG fcTL 帧延迟写精确分数 `delay_num = 1 / delay_den = fps`（fcTL 为 16.16 定点数），60fps 精确表达 16.67ms；默认 `cs` 口径（厘秒 den=100）输出与 v1.3 逐字节一致、configHash 条件序列化不写入（默认指纹不变）。**APNG rect 帧间差分**（`diffMode: rect` 扩展到 APNG 路径）：worker 回传整帧 RGBA（`wantRgba` opt-in），主 isolate 逐字节差分出变化包围矩形 → 区域帧进容器（fcTL 区域 + x/y offset，dispose=NONE/blend=SOURCE 跨帧合成；无变化帧 1x1 占位保住帧时序），内存 O(单帧)。新增 `tool/bench_high_fps.dart`（60fps/2s/120 帧基准：局部动效 rect 省 41–57%，全画面动效零收益 + 耗时 ~2×，体积确定性抽查）与 `doc/high-fps.md`（实测数据 + maxDimension/fps/diffMode/dither 推荐矩阵）。`estimateCost` 纳入 APNG/rect 路径：产物体积区间（`minOutputKb`/`maxOutputKb`，B/px/帧 经验系数拟合自 bench）与耗时系数。新增 `test/high_fps_test.dart`（exact fcTL 解析、区域帧逐像素还原、管线端到端 rect ≤ full、确定性、configHash 稳定性）。
- **确定性效果预览资产**：`tool/generate_showcase.dart --previews-only` 单一真相源产出 40 份低配预览（8fps、1.5s、≤360px，自适应降档梯子 360→280→220→170→130 保证单 GIF < 300KB）至 `doc/previews/<demo>/`（preview.png + preview.gif + 确定性 index.json：key → 分类 → 路径 → 实际档位 → 体积），两轮生成逐字节一致（sha1 锁定）；`kEffectPreviewRefs`（`EffectPreviewRef`，32 项效果映射）交叉引用预览路径；README 效果目录章节链接预览资产。

### 鸿蒙阅读效果对齐

- **路线图与能力边界声明（文档）**：新增 `doc/roadmap.md`——GPU 实时路径（Flutter FragmentShader 实时化参数化变换类效果，独立 shader 伴生包，粒子类二期）、AI 深度/主体检测（服务端/可选伴生包落位优先，守护核心零原生依赖卖点）、分格感知分层（中间态：分格线检测 → 逐格分层）、animated WebP 备选（引用 `doc/webp_research.md`，激活条件与 APNG 的流式内存决策记录），每项标注价值/工作量级/依赖决策点，附非目标清单。README（中英）「环境要求」旁新增**能力边界声明**：本库输出为预渲染动图（GIF/APNG/帧集）而非实时交互渲染，交互视差是离散相位帧集；`realtime/index.html` 仅为翻页手势 Canvas 2D 参考实现；实时路径见 roadmap。修 `.gitignore` 笔误行 `presets/.json`（无实际作用、语义误导；presets 必须保持被跟踪）。
- **Flutter 伴生包 comic_motion_flutter（新增包）**：monorepo 新增伴生包，单向依赖核心包（核心包保持纯 Dart、零 Flutter 依赖不变）。两组即用 widgets——`MotionGifView`：GIF 播放视图，`firstFramePng` 占位 crossfade 无缝过渡（默认 150ms，可直切）、`playing`/`loop` 外部驱动、系统「减弱动态」静帧（`MediaQuery.disableAnimations`，不解码动画）、入场帧序列前置播放后无缝切入循环；`ParallaxGyroView`：交互帧集跟手视差，三种驱动——sensors_plus 陀螺仪（`tiltToPhase` 欧拉角归一化，`maxTiltDeg` 默认 15°，~60fps 节流 + 0.01 死区）、触摸拖动回退（半视口 = 满相位，`returnToCenter` 回中）、`tiltStream` 注入流（测试 mock / 摇杆等自定义驱动挂点，非空时不订阅传感器）；插值 `smooth` 相邻帧 alpha 混合或最近帧直切。纯 Dart 辅助（可脱离 Flutter 单测）：`loadInteractionSets` / `loadInteractionSetsFromIndexJson`（磁盘 / 任意字节存储 → 帧集）。Widget 测试覆盖相位→帧映射（注入流驱动）、触摸回退与回中、占位过渡、减弱动态、入场序列与字节变更重置；CI 新增 flutter 矩阵 job（flutter analyze + test）。example 演示产物接线与 both 拆轴用法；README 中英。核心包 README 新增「生态」章节。
- **APNG 流式编码器**：`OutputFormat` 新增 `apng`（opt-in，默认路径序列化与 configHash 零变化）+ 顶层 `encodeApng(frames, {fps, loopForever, delaysCs})` 与流式 `StreamingApngBuilder`（`addFrame` / `addEncodedPngFrame` / `finish`，内存 O(单帧)）。实现：PNG 容器加 acTL/fcTL/fdAT——帧压缩数据**直接复用既有 PNG 帧编码器的 IDAT 载荷**（不新写压缩代码，与 `frames/frame_NNNN.png` 逐字节同源），真彩色无色带、平色漫画画面体积优于 GIF（测试断言），Chrome/Safari/iOS/Firefox 原生支持；循环语义 acTL numPlays=0（无限循环），帧延迟与 GIF 同口径 `(100/fps).round().clamp(2,100)` 厘秒，dispose=NONE/blend=SOURCE 全画布覆盖。管线集成：apng 模式复用 worker 的 PNG 回传通路（`wantPngBytes`），**并行与串行 APNG 逐字节一致**（测试锁定）；磁盘产物 `anim.apng`，`PipelineResult.outputApng`（toJson 仅在 apng 模式追加键）/ `MemoryPipelineResult.apngBytes`。附带 `decodeApngScanlines`（标准 PNG filter 反演 0-4，测试与嵌入方校验用）。方案对比（APNG vs animated WebP vs WebM/MP4）与 WebP 路线见 `doc/webp_research.md` 与 `doc/roadmap.md`。新增 `lib/src/apng_writer.dart` 与 `test/apng_test.dart`。
- **入场转场帧序列**：`exportEntranceFrames`（内存）与 `exportEntranceFramesFile`（落盘，`MotionPipeline` 扩展方法）——从模糊原图浮现到清晰原图的一次性序列，对齐鸿蒙「章节打开景深入场」。纯 Dart 可分离 box blur（3 轮滑动窗口均值近似高斯，整数累加确定性）作用于分层前的原图（入场是整页效果，跳过深度估算/分层）；可选轻微缩放浮现（默认 1.02→1.0，中心锚定双线性）；不透明帧（RGB 输出契约，alpha 渐入列入 roadmap）；末帧短路直接输出工作分辨率原图——「末帧 = 清晰原图」逐字节成立（测试锁定）。默认 12 帧，`frames`/`maxBlurRadiusPx`（null 自动取工作边长 2%，钳制 [2,24]）/`zoomReveal`/`zoomFrom`/`delayMs` 可调。索引 JSON（`kind: entrance`）携带播放语义 `loop: false, holdOnLast: true`（播完停在末帧衔接正常循环动图）+ 建议帧间隔 delayMs。落盘 `<stem>_<contentHash8>_<configHash8>_entrance/`（MotionCacheManager 识别 kind=entrance，可清理）；cancelToken/timeout/keepPartial 兼容（同交互帧集检查点体系）；串行无随机，同输入同 config 逐字节复现。新增 `lib/src/entrance.dart` 与 `test/entrance_test.dart`。
- **交互式视差帧集**：`FrameCompositor` 新增 `parallaxOverride`（`ParallaxOverride{phaseX, phaseY}`，phase ∈ [-1,1]）——非 null 时视差层位移由调用方直接指定（`dx = amplitude · phaseX · w · 层倍率`，垂直轴经 `verticalRatio` 缩放），替代时间驱动相位；其余效果冻结在 t=0 参考相位。默认 null 下时间驱动路径与 1.3.0 逐字节一致（红线：新旧行为 8 项产物逐字节比对通过，legacy/standard/rect-diff/静帧/混搭效果全同）。新增导出入口 `exportInteractionFrames`（内存）与 `exportInteractionFramesFile`（落盘，`MotionPipeline` 扩展方法）：`steps`（默认 16，均匀采样 [-1,1] 含端点）× `axis`（horizontal/vertical/both——both 输出两组一维帧集）；返回 `InteractionExportResult`（帧集 PNG 字节 + 索引 JSON + 宽高 + configHash/contentHash），索引 JSON（`kind: interactive`）嵌入方加载即用。落盘目录 `<stem>_<contentHash8>_<configHash8>_interactive/`（frame_NNNN.png + index.json），`MotionCacheManager` 识别该契约（条目新增 `kind` 字段），purgeLRU/purgePrefix/purgeAll 正常清理。与 cancelToken/timeout/keepPartial 兼容（检查点：入口 + 每帧渲染前后，粒度帧边界；取消默认清理半成品，异常 code `E_CANCELLED`/`E_TIMEOUT`）。`phase=0` 帧 ≡ 去掉 parallax 效果的 t=0 静帧（逐字节测试锁定）。新增 `lib/src/interaction.dart` 与 `test/interaction_test.dart`。

### 运行时生命周期接口

- **全内存管线 API**：`MotionPipeline.processBytes({required Uint8List input, int? maxPixels})` → `MemoryPipelineResult`（`gifBytes` / `paramsJsonBytes` + 对齐 `PipelineResult` 的元信息，无路径）。渲染主干抽出共享 `_runCore`，`processFile` 只剩薄封装——同输入同配置下内存产物与落盘产物逐字节一致（有测试，含并行路径）。`outputFormat: frames` 在内存模式返回 `gifBytes: null`。
- **取消 / 进度 / 超时**：`MotionPipeline` 新增 `onProgress` / `cancelToken` / `timeout` / `keepPartial`（全部执行期参数，不进 configHash）。检查点全部位于主 isolate 帧调度层（派发前 / 每帧回包 / 探针渲染前），不打断 worker 内部单帧渲染，粒度为一个帧边界；超时用 deadline 比对而非 Timer。取消默认清理本次写出的半成品并抛 `MotionCancelledException`（code `E_CANCELLED`），超时走同一路径（code `E_TIMEOUT`）。进度计数含探针帧、取消后不再回调。新增 `lib/src/cancellation.dart`。
- **后台 isolate 入口**：`processFileInBackground` / `processBytesInBackground`——整条管线（含解码）在后台 isolate 执行。`Isolate.spawn` + 控制通道：config/并行/预算随启动消息下发，progress 经 SendPort 回传，`cancel()` 经 cancelHook 桥即时推送（后台无轮询定时器，检查频率 = 帧调度检查点）；异常对象跨 isolate 原样重抛、`E_*` 错误码不丢。README（中英）新增醒目「线程模型」警告（同步段：decode/depth/split/probe）与两种解法；新增 `example/04` 完整演示进度/取消/超时/内存流程。
- **并发防护（opt-in）**：`MotionPipelineGuard` 进程级 FIFO 信号量（`configure(maxConcurrent)` 默认 1；`acquire/release` 或 `run()` 便捷封装，取消异常同样释放槽位）。README 明确「移动端同一时刻只跑一个渲染任务」指引。
- **一站式渲染参数 API**：`EffectConfig` 构造新增顶层便捷参数 `dither` / `qualityTier` / `amplitude` / `directionDeg`（null = 不触碰；非空映射到 `quality.*` / `parallax.*`，与显式嵌套构造**序列化与 configHash 逐字节等价**，等价性矩阵有测试；默认路径指纹不变）。
- **渲染效果选择 API**：`withEffect` / `withoutEffect` / `withEffects`（全量替换）/ `clearEffects`（静帧）——不可变语义，一律返回新实例。
- **参数目录**：`ParamSpec` + `kRenderParamSpecs`（名称/类型/min/max/默认/语义，`strictRange` 区分 fail-fast 与建议范围）+ `kEffectNames`，供 App 动态生成设置面板。持久化推荐：直接存 `EffectConfig.toJsonString()`、`fromJson` 读回即恢复。`example/02` 扩展链式配置演示。
- **条漫 strip 模式**：`StripSplitter`（视口比例切片，默认 9:16；可选重叠 N px，裁剪语义不做混合；小尾片自动并入）+ `processStrip`（每片走标准管线独立渲染，输出 `<stem>_slice<NNN>_<hash8>/`，片级 configHash 独立、天然缓存去重）+ `kStripSafeEffects` 白名单（白名单外效果允许使用但在 `warnings` 提示实验性）。`MotionPipeline.processImage` 为已解码源图的公共入口（与 processFile 共享渲染主干）。条漫形态（高 > 2×宽）超限时 `E_TOO_LARGE` 消息提示改用 strip 模式。
- **输入格式矩阵（文档）**：README（中英）明确 JPEG/PNG/静态 WebP 支持；**Animated WebP 与 GIF 实测解码成功、引擎取首帧**（手工构造动画 WebP 容器实测 `image` 4.10.1，行为契约有测试锁定，依赖升级漂移会在 CI 暴露）；AVIF/HEIF 以 `E_DECODE_CORRUPT` 拒绝；损坏/伪装文件错误路径表。
- **发布就绪**：包内 `docs/` 按 pub 布局约定改名 `doc/`，`dart pub publish --dry-run` 达到 **0 warnings**（未执行发布）；新增 `doc/release_checklist.md`（dry-run 核查表、双包版本对齐策略、path override ↔ 版本依赖切换时机、score 优化清单、发布后动作）。
- **成本预评估**：`estimateCost(config, {sourceWidth, sourceHeight})` → `CostEstimate`（内存/耗时**区间** + 工作分辨率 + 帧数，基于桌面 bench 拟合、标注经验估算；低端机可行性按上界判断）。
- **移动端参考区间（文档）**：README 性能章节新增草稿/典型/低端三档粗略区间，明确桌面数据不适用于真机、区间未经真机校准。

### 正确性防护与输出消费（文档收尾）

- **GIF 播放消费指引（文档）**：README（中英）新增 Flutter 侧播放章节——内建 `Image` / `extended_image` / `instantiateImageCodec` 选型取舍、解码内存杠杆（渲染期帧数与尺寸、`cacheWidth`/`cacheHeight` 按显示尺寸解码、同屏播放个数）、列表页封面占位（`OutputFormat.both` 的 `frame_0000.png`）与预热 / 暂停 / 减弱动态策略。库保持 UI-free，本节仅为嵌入方参考，不引入任何 UI 依赖。

### 正确性防护功能任务

- **输入内容指纹防串缓存**：产物目录命名纳入输入内容指纹，改为 `<stem>_<contentHash8>_<configHash8>`（strip 片级 `<stem>_slice<NNN>_<contentHash8>_<configHash8>`）。`contentHash8` = 输入字节 FNV-1a 64 指纹前 8 位（`ImageIO.contentHash8`，与 configHash 同风格）；`processImage` 无文件字节，取传入栅格 RGBA 字节计算。`PipelineResult` / `MemoryPipelineResult` 新增 `contentHash` 字段（`PipelineResult.toJson` 同步携带）。内容指纹与配置正交：不进 `EffectConfig` 序列化、不参与 configHash。`processFile` 改为单次读盘（`ImageIO.readFileBytes`，守卫与 `decodeFile` 一致），同一份字节既做指纹又做解码输入。同名文件重新下载 / 覆盖后产物落新目录，嵌入方「目录存在 → 跳过渲染」逻辑不再命中旧画面。
- **首帧 / 静帧输出 API**：`MotionPipeline.renderStillFrame({required Uint8List input, double t = 0, int? maxPixels})` 与 `renderStillFrameFile(path, {t})`——单次渲染 t 时刻静帧、PNG `Uint8List` 出；与全量渲染共享解码→降采样→分层主干（抽出共享 `_downscaleAndSplit`），跳过 GIF 编码与调色板探针，成本 ≈ 单帧渲染；t=0 与 GIF 首帧逐像素同源。受 cancelToken/timeout 管控（入口与渲染前各检查一次）。`processFile` / `processBytes` / `processImage` 新增可选 `includeFirstFrame`（默认 false）→ 结果附 `firstFramePng`：直接复用探针帧 0 栅格、零额外渲染成本，字节与落盘 `frames/frame_0000.png` 一致；后台入口同步透传；`PipelineResult` / `MemoryPipelineResult` 新增可空 `firstFramePng` 字段（不进 toJson）。frames-only 路径无探针段时主 isolate 预渲染第 0 帧并跳过派工，同样只渲染一次。
- **缓存管理组件（新增）**：新增 `MotionCacheManager(rootDir)`（`lib/src/cache_manager.dart`，barrel 导出）——`listEntries()` 解析产物目录契约（单图 + strip 片级形态，从右往左解析 stem / contentHash / configHash / sliceIndex，含 stem 内下划线回溯），`totalSize()` / `entryCount()`，`purgeLRU({maxEntries, maxBytes, olderThan})` 按最近修改时间从旧到新淘汰（三条件可任意组合，返回 `CachePurgeReport` 明细），`purgePrefix(stem)` 清某作品（含全部片级条目）、`purgeAll()`。安全约束：只删除完整匹配契约的目录，无法识别的文件 / 目录一律跳过。configHash8 按管线字面形态解析（负值哈希带前导 `-`，不改写 configHash 本身）。
- **帧流回调**：`MotionPipeline` 新增可选 `onFrame(int frameIndex, Uint8List pngBytes)`——每帧回包时按帧号**有序**触发、一帧恰好一次（含调色板探针帧），与 `onProgress` 并存，取消 / 超时后不再回调。PNG 字节与落盘 `frames/frame_NNNN.png` 同源同字节（worker 侧 `wantPngBytes` opt-in 编码回传，不设置零额外成本）。回调执行在执行管线的 isolate 上（同步入口 = 调用方 isolate）；后台便捷入口经 SendPort 桥接，用户回调执行在调用方 isolate。全部为执行期参数，不进 configHash。
- **GIF 帧间差分（opt-in）**：新增 `EncodingParams`（`EffectConfig.encoding`，条件序列化——默认 `none` 整段不出现，既有指纹零影响）与 `encoding.diffMode: none | rect`。`rect` 模式：worker 并行「渲染 + 量化」回传索引图（量化是逐帧纯函数，dither/sierra 误差扩散逐帧独立、与差分正交），主 isolate 按帧序对相邻索引图差分裁变化矩形 + disposal=1（do-not-dispose）+ 全局调色板 LZW 子矩形编码；首帧全画布，无变化帧以 1×1 占位保帧时序；确定性由按序汇聚点保证。`StreamingGifBuilder` 新增 `rectDiff` / `addIndexedFrame` / `GifFrameEncoder.quantizeIndices`；`kRenderParamSpecs` 增补 `diffMode` 条目。条漫 strip 每片走标准管线自动受益。测试：`none` 缺省与显式同字节（红线）；`rect` 用 GIF89a 规范合成裁判（decodeFrame 裸帧 + disposal 0/1 画布保留语义，规避 image 包 `decode()` 对子矩形帧的合成缺陷）逐像素校验与 `none` 一致（串行 + worker、legacy + standard 档）；体积断言 < 全量编码。
- **Web 支持状态（文档）**：平台支持矩阵明确 Web **不支持**——`image_io` / `pipeline` / `worker_pool` 依赖 `dart:io`，`Isolate.spawn` 在 Flutter Web 不可用；远期方向（web 解码 API + web worker）一句话带过，不做实现承诺。
- **rich 档收尾**：README（中英）明确 `rich` 当前与 `standard` 逐字节等价，`RenderTier.rich` 加 `@Deprecated` 提示（新代码请用 standard）。纯标注：行为、序列化、configHash 零改动，JSON 的 `"tier": "rich"` 仍正常解析，按兼容政策保留。

### ⚠ BREAKING CHANGE

- **产物目录命名规则变更（1.3.1 起）**：`<stem>_<configHash8>` → `<stem>_<contentHash8>_<configHash8>`（strip 片级同步）。旧格式目录不被新布局识别，嵌入方需自行清理旧缓存（内容指纹详见「正确性防护功能任务」首条目）。
- `EffectConfig.fromFile` 移到 IO 边界：改用顶层函数 `effectConfigFromFile(path)`（barrel 导出，错误包装与错误码不变）。`effect_config.dart` 因此为纯 Dart（无 dart:io），Web 可行性评估有据。
- `EngineWorkerException.code` 由静态常量改为实例字段（取值仍为 `E_WORKER_CRASH`）。

### 新增 / 改进

- **包拆分**：CLI/HTTP/台账查询拆至 `comic_motion_server`（见其 CHANGELOG）；本包运行时仅依赖 `image`，导出面保持兼容（另增补 `json_compat`、`config_io` 导出）。
- **跨平台路径**：产物路径全部以 `/` 拼接（POSIX 上 `\` 是合法文件名字符，旧实现会产出名字带反斜杠的平铺文件）；Windows 产物布局与目录命名 `<图名>_<hash8>` 不变；新增 POSIX 路径回归测试。
- **解码像素预算**：`ImageIO.decode/decodeFile` 新增 `maxPixels`（默认 40M 像素）；PNG/JPEG/WebP **头解析即拒**（截断/损坏头部同样拒绝），在分配整幅栅格前防住移动端 OOM；`ImageTooLargeException` 增加 `pixelCount/maxPixels` 字段。
- **异常错误码体系**：`E_DECODE_EMPTY` / `E_DECODE_CORRUPT` / `E_DECODE_NOT_FOUND` / `E_TOO_LARGE` / `E_BAD_CONFIG` / `E_UNKNOWN_EFFECT` / `E_WORKER_CRASH`，与 HTTP API 错误码对齐；异常消息英文化，`toString` 携带错误码。
- **结构参数 fail-fast**：`fps ≥ 1`、`durationSec > 0`、`layerCount ∈ [1,8]`、`maxDimension ≥ 1`、`maxFrames ≥ 2`；非法值抛带码 `ConfigException`（此前按各自通路静默退化出图，fps=0 有除零/NaN 风险）。合法域内默认值、行为与 configHash 完全不变。
- **内存预算 API**：`MotionPipeline(memoryBudgetMb:)`——保守启发式估算层栅格内存，预算不足先降并行、再收缩工作分辨率（下限 320px），每次降级写 `PipelineResult.warnings` 并置 `parallelFallback`。执行期参数：不进 configHash；不传时像素路径零改动。
- **台账可关闭与轮转**：`BatchRunner(null)` 嵌入场景不落台账；`Ledger(maxBytes:)`（默认 16MB）超限轮转 `ledger.jsonl.1`（单代），查询覆盖当前档。
- **工程**：三平台 CI（ubuntu/windows/macos matrix，两包分别 analyze+test）；`example/` 三个可运行示例；`docs/`（动效目录、WebP 调研）与英文 README（README_zh-CN.md 保留中文）纳入仓库；兼容与废弃（@Deprecated 周期）政策成文。

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
