import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// X2（v1.5）：静态层栈合成缓存 —— 无层变换效果时首帧缓存「底图+层栈」，
/// 后续帧整块拷贝后只重画叠加效果。
///
/// 红线锚点：**零输出变化**。缓存由与非缓存路径同一段绘制代码建出
/// （`_drawLayerStack`），本文件用 enableStaticCache on/off 双实例逐帧
/// 逐字节对照锁定；含层变换效果（parallax/breathing/heartbeat/slowPush/
/// mangaShake）的配置缓存自动失效，走原路径；层 clip 与部位形变在缓存
/// 路径上语义不变。
void main() {
  RgbaImage baseRaster() {
    final im = RgbaImage(width: 96, height: 72);
    for (var y = 0; y < 72; y++) {
      for (var x = 0; x < 96; x++) {
        final o = (y * 96 + x) * 4;
        im.data[o] = (x * 255) ~/ 96;
        im.data[o + 1] = (y * 255) ~/ 72;
        im.data[o + 2] = 128;
        im.data[o + 3] = 255;
      }
    }
    return im;
  }

  /// 两层全画布层：层 0 = 底图暗化拷贝（远层），层 1 = 中央色块（前景）。
  /// 可选 [clip] 给前景层带格裁剪（panelAware 语义）。
  List<LayerImage> twoLayers(RgbaImage base, {PixelRect? clip}) {
    final dark = RgbaImage.fromBytes(
        width: base.width,
        height: base.height,
        data: Uint8List.fromList(base.data));
    for (var i = 0; i < dark.data.length; i += 4) {
      dark.data[i] = dark.data[i] * 3 ~/ 4;
      dark.data[i + 1] = dark.data[i + 1] * 3 ~/ 4;
      dark.data[i + 2] = dark.data[i + 2] * 3 ~/ 4;
    }
    final fg = RgbaImage.fromBytes(
        width: base.width,
        height: base.height,
        data: Uint8List.fromList(base.data));
    for (var y = 20; y < 52; y++) {
      for (var x = 28; x < 68; x++) {
        final o = (y * base.width + x) * 4;
        fg.data[o] = 220;
        fg.data[o + 1] = 40;
        fg.data[o + 2] = 40;
      }
    }
    return [LayerImage(dark, 0), LayerImage(fg, 1, clip: clip)];
  }

  Map<String, dynamic> cfgJson(List<String> effects) => {
        'effects': effects,
        'fps': 24,
        'durationSec': 2.0,
        'seed': 42,
      };

  /// on/off 双实例渲染同一组帧，逐字节对照。
  void expectCacheTransparent(List<String> effects,
      {List<PartMotion>? parts, PixelRect? clip}) {
    final config = EffectConfig.fromJson(cfgJson(effects));
    final withCache =
        FrameCompositor(twoLayers(baseRaster(), clip: clip), baseRaster(),
            config, parts: parts);
    final withoutCache = FrameCompositor(
        twoLayers(baseRaster(), clip: clip), baseRaster(), config,
        parts: parts, enableStaticCache: false);
    for (final t in [0.0, 1 / 24, 0.5, 1.0, 7 / 24]) {
      final a = withCache.renderFrame(t);
      final b = withoutCache.renderFrame(t);
      expect(
        a.data,
        b.data,
        reason: 't=$t 的帧在缓存开/关下必须逐字节一致（effects=$effects）',
      );
    }
  }

  test('叠加效果集（rain+lightSweep）：缓存开/关逐字节一致', () {
    expectCacheTransparent(['rain', 'lightSweep']);
  });

  test('粒子氛围集（snow+fireflies+ambient）：缓存开/关逐字节一致', () {
    expectCacheTransparent(['snow', 'fireflies', 'ambient']);
  });

  test('漫画动势集（focusLines+impactRings+screenTone）：缓存开/关逐字节一致', () {
    expectCacheTransparent(['focusLines', 'impactRings', 'screenTone']);
  });

  test('部位动作（handMotion+侧车形变）：缓存开/关逐字节一致', () {
    final sidecar = '{"version":1,"parts":[{"kind":"hand",'
        '"polygon":[[0.3,0.3],[0.5,0.3],[0.5,0.5],[0.3,0.5]],'
        '"anchor":{"x":0.4,"y":0.5,"joint":"wrist"}}]}';
    final parse = PartMotionParser.parse(sidecar);
    expect(parse.warnings, isEmpty, reason: '合法侧车不应产生告警');
    expectCacheTransparent(['rain', 'handMotion'], parts: parse.spec!.parts);
  });

  test('层带格裁剪（panelAware 语义）：缓存路径上 clip 语义不变', () {
    expectCacheTransparent(['rain'], clip: const PixelRect(10, 8, 60, 50));
  });

  test('含层变换效果（parallax+breathing）的配置不走缓存，输出仍一致', () {
    // 缓存门自动失效 ⇒ 两实例同走非缓存臂；本用例锁定该等价性不因重构漂移。
    expectCacheTransparent(['parallax', 'breathing', 'rain']);
  });

  test('缓存臂确定性：独立双实例同 t 渲染逐字节一致', () {
    final config = EffectConfig.fromJson(cfgJson(['rain']));
    final f1 = FrameCompositor(twoLayers(baseRaster()), baseRaster(), config)
        .renderFrame(1 / 24);
    final f2 = FrameCompositor(twoLayers(baseRaster()), baseRaster(), config)
        .renderFrame(1 / 24);
    expect(f2.data, f1.data);
    expect(f1.data.length, 96 * 72 * 4);
  });
}
