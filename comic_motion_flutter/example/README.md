# comic_motion_flutter example

伴生包 widgets 的最小演示。产物不入库（`assets/` 内容 gitignore），运行前先准备：

```bash
# 1. 用核心包 CLI 导出（monorepo 根目录）
cd comic_motion_server
dart run bin/render.dart -i ../sample_images/<你的图>.png \
    -o ../comic_motion_flutter/example/assets/demo
dart run bin/export_interaction.dart -i ../sample_images/<你的图>.png \
    -o ../comic_motion_flutter/example/assets/demo_pan

# 2. 跑示例
cd ../comic_motion_flutter/example
flutter pub get && flutter run
```

> CLI 子命令与参数名以核心包 README「命令行工具」为准；产物目录命名含
> contentHash/configHash 尾缀，若与上面固定路径不同请按实际目录名调整
> `lib/main.dart` 顶部的 `_kGifDir` / `_kPanDir` 常量。

演示内容：

- **MotionGifView**：`first_frame.png` 占位 → GIF crossfade 接管；可选入场帧
  序列（`anim.entrance/`）前置播放；播放/暂停按钮驱动 `playing`。
- **ParallaxGyroView**：交互帧集内存加载（`loadInteractionSetsFromIndexJson`
  + asset 回调，展示 both 产物拆轴用法）；真机陀螺仪 + 桌面触摸回退。
