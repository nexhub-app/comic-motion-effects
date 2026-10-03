# comic-motion-effects

纯 Dart 漫画动效引擎 monorepo：两个 Dart 包 + 一个静态演示页。

| 目录 | 包 | 说明 | 发布形态 |
|---|---|---|---|
| [`comic_motion/`](comic_motion/) | `comic_motion` | 渲染引擎：深度分层拆解 + 33 种动效（部位动作 `handMotion` 为 opt-in，部件由 `part_motion.json` 侧车提供）+ 字节级可复现的 GIF/PNG 输出。运行时仅依赖 `image`，可直接嵌入 Flutter/Dart 应用 | pub.dev |
| [`comic_motion_server/`](comic_motion_server/) | `comic_motion_server` | CLI（process / batch / job / serve）+ HTTP API + JSONL 处理台账，依赖引擎包 | git / 自托管 |
| [`realtime/`](realtime/) | — | Canvas 2D 实时翻页动效演示（纯静态单文件，零依赖） | 静态托管 |

CI（[![CI](https://github.com/nexhub-app/comic-motion-effects/actions/workflows/ci.yml/badge.svg)](https://github.com/nexhub-app/comic-motion-effects/actions/workflows/ci.yml)）在 ubuntu / windows / macOS 三平台对两个包分别跑 `dart analyze` + `dart test`。

快速开始与用法见各包 README；动效目录、渲染档位、复现承诺等引擎文档在 [`comic_motion/README.md`](comic_motion/README.md)。

## License

[Apache-2.0](LICENSE)
