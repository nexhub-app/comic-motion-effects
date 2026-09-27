# 部署与回滚手册

版本 1.3.0 · 适用 Windows / Linux / macOS

## 一、部署步骤

### 1. 环境准备

- 安装 Dart SDK ≥ 3.4.0（https://dart.dev/get-dart ；验证环境 3.13.0）
- 确认 `dart --version` 可用；内存 ≥ 4 GB

### 2. 发布物

本目录**是** git 仓库，仓库根就是 `comic-motion-backend/`（此前手册与多份文档写的「不是 git 仓库」有误：那是在上一级 `E:\comic motion effects` 里执行 git 得到的结论，那里确实不是仓库）。仓库现状有两点必须知道：

- 当前分支 `main` 只有 4 个提交，`origin/main` 的远端引用已丢失（`main...origin/main [gone]`）；
- `v1.0.0 / v1.1.0 / v1.2.0 / realtime-v1` 四个标签所在的提交线与 `main` **没有共同祖先**（`git merge-base v1.2.0 HEAD` 无输出），所以标签只能 `checkout` 到 detached HEAD 看旧代码，不能对 `main` 做 `revert`/`merge` 式的版本回退。

因此**发布与回滚单元都走配置开关**（下一节），git 只用于取代码与查历史。部署前自检：

```bash
dart pub get               # 仅此一步需要网络
dart test                  # 124 例
dart analyze lib test tool bin   # 期望 No issues found!
dart run bin/comic_motion.dart --version   # 期望与 pubspec.yaml 一致
```

若要在自己的远端（GitHub 等）上托管，先修好 `origin`（当前 `origin/main` 已 gone），再自打标签；本手册的「回滚」一节不依赖 git。

### 3. 启动

```bash
# 前台
dart run bin/comic_motion.dart serve --port 8787 --data-dir DELIVERY/data

# Windows 后台（示例）
Start-Process dart -ArgumentList 'run','bin/comic_motion.dart','serve','--port','8787' -WindowStyle Hidden
```

### 4. 健康检查

```bash
curl http://127.0.0.1:8787/health
# 期望 200 {"status":"ok","version":"1.3.0",...}
```

### 5. 冒烟验收

```bash
dart run tool/smoke_test.dart   # 期望输出 SMOKE OK
```

## 二、回滚方案（已演练验证）

回滚单元 = **配置开关**，不需要动代码或产物。四级收回（细则见 `docs/motion_catalog_v13.md` §五）：

| 想收回什么 | 开关 | 代价 |
|---|---|---|
| 单个动效 | `effects` 列表里删掉它的名字 | 其余不受影响 |
| 情绪编排 | `"moodScript": {"strength": 0}` | 与不挂该效果逐字节等价 |
| 像素质量（AA/重采样/screen 混合/三帧调色板） | `--quality legacy` | 新动效保留，只回像素通路 |
| 全部新行为 | `--config presets/classic.json` | 回到经典配置的基线行为 |

**逐字节证据**（2026-09-19 复跑）：`presets/classic.json` 跑全部 10 张样图（`parallel=4`），输出 GIF 的 SHA256 与 2026-09-14 采集、v1.2 轮冻结的 `build/rollback_baseline/hashes.txt` **10/10 一致**（明细 `build/rollback_v13_drill/hashes.txt`，可重跑：`dart run build/rollback_drill_v13.dart`）。配置指纹锁定 `default = -477687d5e8bded5f`、`classic = 2e1a45e07164337e`。

代码回退 = `git checkout <旧标签或提交>` 后重装依赖；产物/服务回退 = 换回旧快照目录：

```bash
# 1. 停服务（杀 dart 进程或停 Windows 服务）
# 2a. 代码回退：切到旧标签（会得到 detached HEAD），或用旧快照目录整体替换新目录
git checkout v1.2.0
# 3. 依赖无变化时可跳过
dart pub get
# 4. 重启服务并健康检查 + 冒烟
curl http://127.0.0.1:8787/health
dart run tool/smoke_test.dart
```

注意：
- `git checkout` 前先确认工作区干净（`git status`）；`git reset --hard` / `git clean -fd` 会连带丢掉 `v1.3` 的未提交改动，本手册**不**把它们当作回滚手段。标签线（`v1.0.0`~`v1.2.0`）与 `main` 无共同祖先，切过去只能看旧代码，合不回新分支。
- 台账 `ledger.jsonl` 为 JSONL 追加型，跨版本兼容（旧版本读到新字段会忽略），回滚不销毁历史记录。
- 输出目录按 `<stem>_<hash8>` 命名，新旧版本产物互不覆盖；回滚后新任务落新目录。
- v1.3 起配置里写错的效果名会直接抛 `ConfigException`（此前静默退化成 `parallax`），跨版本搬 `params.json` 时先核对效果名。

## 三、版本记录

| 版本 | 标签 | 日期 | 说明 |
|---|---|---|---|
| 1.0.0 | `v1.0.0` | 2026-09-14 | 首个发布：引擎+API+CLI+台账+批处理+测试+基准 |
| 1.1.0 | `v1.1.0` | 2026-09-15 | 新增 8 动效 + 预设体系 + reducedMotion + 效果图鉴；经典配置输出与 1.0.0 逐字节一致（回滚安全） |
| 1.2.0 | `v1.2.0` | 2026-09-15 | 再增 8 动效（流雾/余烬/闪电/色调呼吸/暗角/星光/推镜/波光）+ GIF 抖动 `QualityParams.dither`；`default`/`classic` 两个指纹不变 |
| 1.3.0 | 尚未打 | 2026-09-19 | 新增 11 动效（漫画动势 5 + 自然氛围 5 + `moodScript`）+ `RenderTier legacy/standard/rich` 质量层 + isolate 并行帧渲染；`RgbaImage.data` 改 flat `Uint8List`（**BREAKING**，仅影响把包当库直接摸像素的用法）；legacy 档输出与 v1.2 冻结基线逐字节一致（10/10 实测） |

前三个标签在一条与 `main` 无共同祖先的提交线上（见 §2），所以它们能 `checkout` 但不能与新分支合并；`v1.3.0` 标签与本轮改动的提交都还没做。
