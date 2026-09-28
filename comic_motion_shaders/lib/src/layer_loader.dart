/// 分层纹理装载（W7）：把核心包 W6 `exportLayers` 产出的 RGBA PNG 字节
/// 解码为 Flutter `ui.Image`，供 `RealtimeMotionView` 绑定到 uber-shader
/// sampler。
///
/// 层序约定：输入顺序 = exportLayers 层序（格序 × 格内 rank，远→近），
/// 与 shader uTex0..uTex3 一一对应；层数 >4 时截取前 4 层（与 shader
/// sampler 上限一致）。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'motion_uniforms.dart' show kMaxLayers;

/// 解码分层 PNG 字节列表为 ui.Image 列表（保持输入序，上限 [kMaxLayers]）。
Future<List<ui.Image>> decodeLayerTextures(List<Uint8List> pngs) async {
  final out = <ui.Image>[];
  for (final bytes in pngs) {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    out.add(frame.image);
  }
  if (out.length > kMaxLayers) {
    return out.sublist(0, kMaxLayers);
  }
  return out;
}
