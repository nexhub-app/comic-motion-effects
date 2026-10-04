# comic_motion 发布 checklist（R8）

> 流程文档：发布前逐项核查。**本文档不代替发布执行**——`dart pub publish`
> 必须由维护者手动发起；执行前最后跑一遍 `dart pub publish --dry-run`，
> 确认 `Package has 0 warnings`（布局警告已于 2026-09-27 修复：包内
> `docs/` 已按 pub 布局约定改名 `doc/`，`--dry-run` 实测通过）。

## 一、dry-run 核查项（每次发布前）

| 项 | 命令/位置 | 通过标准 |
|---|---|---|
| dry-run 零警告 | `dart pub publish --dry-run`（在 `comic_motion/`） | `Package has 0 warnings`；打包清单里**不得出现** `pubspec_overrides.yaml`、`build/`、`.dart_tool/` |
| 干净 git 状态 | dry-run 自查 | 无 "checked-in files are modified" 警告（先 commit 全部改动） |
| License | 包根 `LICENSE` | Apache-2.0 在位（pub 识别为 license 文件） |
| description | `pubspec.yaml` | 长度 60–180 字符、纯英文陈述句（现值合规，dry-run 无告警） |
| repository | `pubspec.yaml` | 指向 GitHub 仓库根（monorepo 根，`path` 由 pub 从 repository 推断） |
| topics | `pubspec.yaml` | 已填 `dart/flutter/gif/animation/image`（≤5 个） |
| CHANGELOG | 包根 `CHANGELOG.md` | 本次版本号条目在位（pub.dev 会展示最新一节） |
| 版本三元一致 | `pubspec.yaml` = `lib/src/version.dart` = CLI `--version` | 三处同值 |
| 分析与测试 | 两包分别 `dart analyze` / `dart test` | 0 error、全绿（CI 三平台 matrix 同门禁） |
| example 可跑 | `dart run example/01..04` | 全部正常退出、产物齐全（pub.dev 的 example 计分项） |
| legacy 复现演练 | `presets/classic.json` 走 `tool/smoke_test.dart` | 与历史输出逐字节一致（红线 #1 的发布前复核） |

## 二、双包版本对齐策略

- `comic_motion`（发布到 pub.dev）与 `comic_motion_server`（`publish_to: none`）
  当前同为 1.3.0，**没有硬性同步义务**，但约定：
  - server 依赖声明用 `comic_motion: ^<兼容版本>`（当前 `^1.3.0`），engine
    发布 minor/patch 升级时 server 无需跟着发版（path override + 版本区间
    双通道见下）。
  - engine 出现 **BREAKING CHANGE（major 或带 @Deprecated 清算的 minor）**
    时，server 必须在同一 PR 内升级依赖下限并同步发版。
  - 两包 CHANGELOG 各自独立维护；engine 的行为变化条目以 engine
    CHANGELOG 为准，server 只记录自身（CLI/HTTP/台账）变化。
- `comic_motion_flutter`（0.1.0 起）与 server 同策略（`publish_to: none`
  不适用于 flutter 包，发布到 pub.dev；path override 同第三节）。**发布
  时序硬约束**：伴生包消费 V1/V2 新 API（`exportInteractionFrames` /
  `exportEntranceFrames` / 产物 index.json 契约），这些 API 尚未随
  engine 稳定版发布——伴生包发版前，engine 必须先发布包含对应 API 的
  版本，并把伴生包 `pubspec.yaml` 的 `comic_motion: ^1.3.0` 下限提到
  实际包含这些 API 的版本。

## 三、path override ↔ 版本依赖的切换时机

切换规则：

| 阶段 | server 的依赖形态 |
|---|---|
| 日常开发 / CI | `pubspec_overrides.yaml`（path 指向 `../comic_motion`）；CI 依赖解析全部落在 `pubspec.lock`，钉版本防漂移 |
| engine 已发新版、server 需要立即用 | 临时保持 override，直到对应 engine 版本出现在 pub.dev |
| engine 新版**已发布**后 | **删除**（或注释）`pubspec_overrides.yaml`，让 `comic_motion: ^x.y.z` 版本区间接管；再跑 `dart pub get` 刷新 server 的 lock |
| 回滚 | 恢复 override 文件即可，git 无需回退 |

> 关键时机原则：**override 只在「本地改动尚未发布」时存在**。engine 的
> 每个已发布版本之后，server 都应尽快切回版本依赖，保证 CI 测的是
> pub.dev 用户真实拿到的产物。

**执行记录（2026-09-28）**：engine 1.3.1 已发布 pub.dev，server 已删除
`pubspec_overrides.yaml` 并切至 `comic_motion: ^1.3.1`（`dart pub get` 验证
hosted 解析、6 例契约测试全绿）；两个伴生包与两个 example 同步删除
override，统一走版本依赖。

**执行记录（2026-10-04）**：engine 1.4.0 经 tag `v1.4.0` 触发 OIDC 自动
发布至 pub.dev（publish workflow 内 test + dry-run 门禁通过）；server 切至
`comic_motion: ^1.4.0` 并删除 `pubspec_overrides.yaml`，CI 拆除
pre-publish window 临时 wire 步骤，恢复测 pub.dev 真实产物。

## 四、pub.dev score 优化清单

| 计分项 | 现状 | 动作 |
|---|---|---|
| Documentation | API doc comment 覆盖良好（R1–R6 新增 API 全部带 doc） | 发布前 `dart doc` 跑一遍确认无 orphan/弃用引用；如需外链可加 `documentation:` 字段 |
| Example | `example/` 四个可运行示例（01–04） | 保持可跑；pub.dev 识别包根 `example/` 目录 |
| Platform 标记 | 纯 Dart 包，无需声明 flutter platforms | 保持 pubspec 不含 `flutter.plugin`；topics 已含 `dart`/`flutter` |
| Analysis | `lints: ^4.0.0` 全绿 | 维持 0 issue；升 Dart SDK 时同步 `environment.sdk` |
| 依赖健康 | 唯一运行时依赖 `image` | 升级 `image` 前跑复现演练（README 复现边界：跨编码器实现的字节漂移风险） |

## 五、发布后动作

1. 给仓库打 tag（`comic_motion-v<version>`），GitHub Release 引用
   CHANGELOG 该节。
2. server 切回版本依赖（见第三节），跑两包全量测试。
3. README badge / 安装片段核对 `^<version>` 与发布值一致。
4. 下一版本号按 SemVer 预热：feature 进 minor，修复进 patch；破坏性变更
   遵循 README「兼容与废弃」政策（@Deprecated 周期至少一个 minor）。
