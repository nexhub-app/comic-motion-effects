# 动效目录 v1.3 —— 漫画动势 + 自然氛围 + 情绪编排 + 质量层

> 载体：comic-motion-backend 纯 Dart 动效引擎。本轮三条主张：**把漫画的分镜语言做成动效**（集中线/网点/波环/笔触/震动）、**把自然现象再补五种**（火/烟/泡/叶/流星）、**把「什么时候该重、什么时候该轻」抽成一条可编排的曲线**（`moodScript`）。质量与性能是这三条主张的前提，不是并列目标。
>
> 硬承诺（全部实测，非设计意图）：默认/经典配置的 `configHash` 未变，输出字节与 v1.2 轮冻结的基线逐字节一致（v1.3 复跑 10/10；该基线在 v1.2 轮文档中已记录为与 v1.0.0 输出一致，本轮未对 v1.0.0 产物直接复测）；`moodScript.strength=0` 与不挂该效果逐字节等价；`--parallel n` 只改耗时不改字节。

## 一、v1.3 新增动效（11 个，全部整循环无缝 + 独立随机流 + 可个开关）

| # | 效果 | 类别 | 触发场景 | 预期观感 | 作用 | 参数（默认） |
|---|---|---|---|---|---|---|
| 1 | focusLines 集中线 | 漫画动势 | 顿悟、凝视、决意、镜头收束 | 楔形黑线从画外收束到焦点，成组呼吸 | 引导视线（聚焦） | lines 28 / focal 0.5×0.45 / innerFrac 0.26 / wedgeDeg 2.4 / turnCycles 1 / opacity 0.34 / mode black |
| 2 | screenTone 网点 | 漫画动势 | 心理描写、阴影面、印刷质感 | 斜向网点阵列整周期漂移、墨点浓淡往复 | 营造氛围（质感） | spacingPx 8 / density 0.34 / drift 2×1 / densityCycles 1 / angleDeg 30 / opacity 0.16 / mode dot |
| 3 | impactRings 冲击波环 | 漫画动势 | 斗气爆发、重击命中、落地 | 同心环自焦点外扩并收薄，可叠内缘暗描边 | 引导视线（冲击） | rings 3 / outerFrac 0.55 / thicknessPx 3.4 / pulses 2 / opacity 0.5 / mode ring |
| 4 | brushStreak 笔触速度带 | 漫画动势 | 冲刺、闪身、擦身而过 | 带飞白断口的粗笔触横向掠过成组脉冲 | 动势强调 | streaks 12 / lengthFrac 0.42 / thicknessPx 7 / angleDeg 8 / pulses 2 / gapFreq 0.11 / opacity 0.40 |
| 5 | mangaShake 画面震动 | 漫画动势 | 重击、地震、惊愕 | 衰减式抖动位移叠加微量旋转，爆点间静默 | 动势强调（冲击） | shakes 6 / amplitude 0.006 / decay 0.72 / rotJitDeg 0.12 |
| 6 | flame 火焰 | 自然氛围 | 篝火、炉火、焚烧 | 多火舌自下扭动上升、顶端闪烁分叉 | 营造氛围+光源暗示 | tongues 14 / riseCycles 2 / heightFrac 0.18 / flickerCycles 6 / hot fff3b0 / cold ff5a1e / opacity 0.72 |
| 7 | smoke 青烟 | 自然氛围 | 香烟、烟囱、余烬 | 烟团上升中变大变淡、被湍流推偏 | 营造氛围 | puffs 16 / riseCycles 1 / sizePx 26 / turbulence 0.35 / opacity 0.14 / color c9ccd4 |
| 8 | bubbles 气泡 | 自然氛围 | 水下、沐浴、饮品 | 带高光环的气泡左右蛇行上浮，大的快 | 引导视线（上升动势） | count 18 / riseCycles 1 / sizePx 6.5 / wobblePx 10 / opacity 0.5 / color dff2ff |
| 9 | leaves 落叶 | 自然氛围 | 秋日行道、离别、庭院 | 叶片飘落时**翻面变窄**、侧视切深色叶脉 | 营造氛围+季节信息 | count 22 / fallCycles 1 / sizePx 6.8 / flipTurns 2 / swayPx 26 / opacity 0.88 / palette autumn |
| 10 | meteors 流星 | 自然氛围 | 夜空、许愿、预兆 | 窗口式划过：亮头带长尾斜掠，多数时刻天空安静 | 引导视线（偶发） | count 5 / streakCycles 2 / angleDeg 32 / lengthFrac 0.22 / windowFrac 0.18 / opacity 0.85 |
| 11 | moodScript 情绪包络 | 节奏编排 | 全片节奏设计 | 不画像素，只按曲线重排已有动效的轻重 | 节奏与情绪 | mood tension / cycles 1 / strength 1.0 |

**组合演示（3）**：分镜重击（focusLines+mangaShake+impactRings+impactFlash+mood burst）、夜战（speedLines+lightning+embers+vignette+mood tension）、静谧黄昏（fog+leaves+fireflies+godRays+toneShift+mood calm）。

### `leaves` 与 `sakura` 的区别（避免被当成重复实现）

樱花的自转是**平面内旋转**（`spinTurns`），落叶是**绕长轴翻面**（`flipTurns`）：宽度按 `|cos(2π·flipTurns·u+φ)|` 收缩，`|f|<0.30` 判为侧视并切到深色叶脉色，正/背面在 `pal[0]/pal[1]` 间分色。实测翻面只改明暗节奏不改总落墨量（`flipTurns` 0/2/5 → 1956/1871/1899 像素）。

### `meteors` 的窗口式设计（不做常驻流星雨）

与 `lightning` 同族：第 k 颗只在 `(streakCycles·u + k/n) % 1 < windowFrac` 时可见，包络 `sin(π·local)` 两头归零，所以 40 个等距时刻里 14 个完全无流星——常驻会让「偶发」变成「背景噪声」。推进量取 `travel = 1.15·diag·(local-0.5)`，让包络峰值正好落在画面中央（早期写 `(local-0.2)` 时最亮的一刻整条还在画外）。

## 二、`moodScript` 曲线表（关键点取值，相邻点 smoothstep 插值）

| mood | 语义 | motion 轨迹 | particles | exposure | warmth | vignette |
|---|---|---|---|---|---|---|
| tension | 低平蓄力 → 0.35 尖峰 → 骤收 | 0.60 →1.35→ **1.60** →0.70→ 0.60 | 0.70~1.40 | 0.90~1.35 | 0~0.10 | 0.10~-0.15~0.05 |
| calm | 0.97~1.04 极缓四段错相 | 0.97~1.04 | 0.98~1.03 | 0.99~1.02 | ±0.02 | ±0.02 |
| burst | 0.15 爆发 → 指数衰减 → 0.70 余波 | **1.80** →1.25→1.05→1.10→1.00 | 1.00~1.55 | 1.00~1.45 | 0~0.12 | -0.18~0 |
| eerie | 每 1/4 循环一次轻微下沉 | 1.00→0.88→1.00（×4） | 0.92~1.00 | 0.94~1.00 | -0.02~-0.04 | 0~0.12 |

五个乘入点：`motion` → 视差 `ampPx` 与呼吸 `amplitude`；`particles` → 8 处粒子 alpha + 5 个自然氛围 pass；`exposure` → `lightSweep`/`godRays`/`impactFlash`/`lightning`/`shimmer`；`warmth` → `toneShift.shift + warmth`；`vignette` → `strength × (1 + vignette)`。

**恒等因子必须逐位精确**：`x * 1.0` 与 `x + 0.0` 在 IEEE-754 下是 bit-exact，所以未启用（或 `strength=0`）时 legacy 路径一位都不动；这条不变量在 `test/engine_test.dart` 里用「全部 `EffectKind` 组合 × 三个 tier × 4 个时刻」逐字节比对锁定。`toneShift` 的 `warm` 必须保持 **int**（`+ _env.warmth` 折进原有 `.round()` 里），否则下游 `(warm * 0.4).round()` 从整数乘变浮点乘，回滚链当场断裂。

## 三、质量项落地情况（Q1-Q8）

| # | 项 | 方案 | 档位 | 实测成本 | 状态 |
|---|---|---|---|---|---|
| Q1 | 像素模型换 `Uint8List` | `RgbaImage.data` 扁平化 + `fromBytes` 零拷贝 | 全档 | 负成本 | ✅ **BREAKING**（见 CHANGELOG 1.3.0） |
| Q2 | isolate 并行池 | `FrameJob` 纯函数 + `TransferableTypedData` + 有界窗口 `workerCount×2` | 全档 | 负成本（8 worker → 3.5×） | ✅ |
| Q3 | AA 覆盖度原语 | `raster.dart` Wu 线段 + 圆/环/楔解析距离 → smoothstep 覆盖率 | standard+ | +6~10% | ✅ |
| Q4 | 重采样分级 | `scale<1` 面积平均、`scale>1` 可分离 Catmull-Rom | standard+ | +8~12%（二维 16 抽点版曾 5863ms，可分离化后 −36%） | ✅（未触发 §6 降双线性回退） |
| Q5 | 光照感知加法 | `_blendAddPx` → screen 混合 | standard+ | ~0 | ✅ |
| Q6 | 分层质量 | 深度双线性上采样 + `featherPx` 掩码羽化 + 层边缘外扩 `edgeStretchPx` | standard+ | 一次性 +150~250ms | ✅ |
| Q7 | GIF 量化 | 5-5-5 定长 LUT（32768 项）+ 首/中/末三帧调色板采样 + `sierra` | standard+（LUT） | 负成本 | ✅ |
| Q8 | IO 批量化 | `Image.fromBytes`/`getBytes`，PNG 编码进 worker | 全档 | 负成本 | ✅ |
| Q9 | 档位分级 | `RenderTier legacy/standard/rich`，legacy 逐字节复现 v1.2 | — | — | ⚠ **`rich` 当前与 `standard` 等价**：`RenderTier.supersample` 与 `QualityParams.mipLevels` 已定义无消费方 |

## 四、性能实测（`dart run tool/bench.dart`，2026-09-19，同机 18 核，JIT 预热后二跑）

| 场景 | 效果数 | 档位 | 耗时 | 峰值 RSS | 红线 |
|---|---|---|---|---|---|
| draft_480p（480/12fps/2s） | 3 | legacy | 233 ms | 377 MB | ≤450 ms ✅ |
| typical_1080p（1080/24fps/4s） | 3 | legacy | 2 248 ms | 534 MB | ≤5 000 ms ✅ |
| preview_1600（1600/24fps/4s） | 3 | legacy | 3 491 ms | 607 MB | ≤7 000 ms ✅ |
| rich_1080p（v1.2 全开基线） | 19 | legacy | 2 702 ms | 607 MB | ≤v1.2 基线 ✅ |
| standard_1080p | 3 | standard | 4 262 ms | 607 MB | — |
| rich_tier_1080p（+ sierra） | 19 | rich | 4 704 ms | 628 MB | — |
| **v13_full_1080p** | **32** | **standard** | **5 201 ms** | 628 MB | ≤9 000 ms ✅ |

并行度扫描（standard 档 / 1080p / 96 帧 / 三件套）：`1 → 16 666 ms`、`2 → 9 451 ms`、`4 → 6 075 ms`、`8 → 4 770 ms`；四次 GIF 字节一致，`parallel=1` 峰值 628 MB（红线 780）。并行取 8 而非 18：worker 各持一份层栅格副本，收益 6-8 后转平而内存线性上升。

单效边际代价（900×1300 / 24fps / 4s / 96 帧，rich 档 + sierra，`build/perf_*` A/B）：五个漫画动效 **+405 ms**、五个自然氛围 **+746 ms**（≈7.8 ms/帧），对照同批五效复测 +249 ms——本机噪声区间内。

## 五、回滚与兼容（四层收回）

| 层级 | 手段 | 操作 | 粒度 |
|---|---|---|---|
| 按个关闭 | effects 列表增删 | `--effects parallax,breathing` | 单个动效 |
| 只关调制 | 包络强度归零 | `"moodScript": {"strength": 0}` | 编排层（逐字节等价） |
| 只回画质 | 渲染档位 | `--quality legacy` | 像素通路（保留新动效） |
| 整体关闭 | 经典预设 | `--config presets/classic.json` | 全部（等价 v1.2 基线的经典行为） |

- 序列化：11 个新参数段与 `moodScript` 一律 `if (effects.contains(X))` 条件写入；`quality` 段全默认时整段不写。锁定指纹：`default = -477687d5e8bded5f`、`demo_640 / classic = 2e1a45e07164337e`。
- 回滚演练（2026-09-19 复跑）：classic 配置跑 10 张样图（`parallel=4`）→ 输出 GIF 的 SHA256 与 `build/rollback_baseline/hashes.txt`（2026-09-14 采集、v1.2 轮冻结）**10/10 逐字节一致**（明细 `build/rollback_v13_drill/hashes.txt`）；帧序列对照 `build/v12_baseline/`（36 帧 + `anim.gif` + `params.json` 共 38 个文件全一致）。同一次演练同时证明并行与串行逐字节一致。
- 收回**不依赖 git**：本目录确实是 git 仓库（根 = `comic-motion-backend/`，且有 `v1.0.0`~`v1.2.0` 标签），但那三个标签所在的提交线与当前分支 `main` **没有共同祖先**，切标签只会得到 detached HEAD，合不回新分支；v1.3 的改动此前也全部未提交。所以四层收回一律走上面的配置开关，逐字节一致性由 §五的演练证明。

## 六、时间戳台账

引擎侧台账：`<data-dir>/ledger/ledger.jsonl`（CLI `process/batch` 与 HTTP API 同源追加，一行一任务：`jobId / ts / input / configHash / status / frameCount / elapsedMs / parallel / 产物路径`，未知 `mood` 时另带 `warnings` 数组）。查询：

```bash
dart run bin/comic_motion.dart job all            # 或 job <jobId>
dart run bin/comic_motion.dart job all --data-dir build/mood_data   # 演练用独立台账
```

图鉴 37 组演示由 `tool/generate_showcase.dart` 直出（不走 CLI，故不落 ledger），逐条可审计的存档是每目录的 `params.json`（完整回放参数）+ `presets/<key>.json`（同源预设）。v1.3 新增 15 条：

| key | configHash | 帧数 | anim.gif |
|---|---|---|---|
| focus_lines_action | `-6dc297c0b3cb0127` | 36 | 4 307 KB |
| screen_tone_closeup | `357b317c5ae49843` | 36 | 4 529 KB |
| impact_burst | `225fdded12f28982` | 36 | 3 840 KB |
| brush_streak_run | `09a207df03656897` | 36 | 5 106 KB |
| manga_shake_impact | `2fc069a03e0feebd` | 36 | 4 977 KB |
| flame_campfire | `-65ff9c322f906c0f` | 36 | 4 103 KB |
| smoke_indoor | `05f4426b1f074f6d` | 36 | 3 549 KB |
| bubbles_underwater | `-419300799ad5ac6c` | 36 | 3 726 KB |
| leaves_autumn | `69f2fa1d74d2e728` | 36 | 3 620 KB |
| meteors_night | `-63cc9da9c66ab327` | 36 | 2 481 KB |
| mood_tension_build | `-33d946040fa0dc88` | 36 | 5 100 KB |
| mood_burst_impact | `4e3ec44f00a54c73` | 36 | 4 063 KB |
| combo_manga_impact | `49ec847ffcca4a1b` | 36 | 4 636 KB |
| combo_night_battle | `55894b24f8753f91` | 36 | 2 542 KB |
| combo_peaceful_evening | `36dca20dcdbbce57` | 36 | 3 475 KB |

统一口径：`fps 12 / durationSec 3 / maxDimension 512 / quality.tier standard`，视差与呼吸 `periodSec` 显式设为 3——默认的 6s/4s 周期在 3s 片段上首尾不等，会破坏无缝承诺。整目录 87 MB，单卡 2.5-5.1 MB。
