import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// W5：分格感知分层 —— 横向白带检测、逐格独立分层、格边界裁剪。
///
/// 红线锚点：panelAware 默认 false 不写入序列化（configHash 不变）；单格/
/// 无白带图 on/off 逐字节等价（自动回退）；多格图白带行不串色（格边界
/// 裁剪）；并行（worker 携带 ranks/clips）与串行产物一致；确定性。
void main() {
  /// 两格竖排图：上格红块（30..120）、白带（140..160）、下格蓝块（180..280）。
  RgbaImage twoPanelRaster() {
    final im = RgbaImage(width: 200, height: 300);
    for (var y = 0; y < 300; y++) {
      for (var x = 0; x < 200; x++) {
        final o = (y * 200 + x) * 4;
        im.data[o + 3] = 255;
        if (y >= 140 && y < 160) {
          im.data[o] = 255;
          im.data[o + 1] = 255;
          im.data[o + 2] = 255;
        } else if (y < 140) {
          final inRed = y >= 30 && y < 120 && x >= 40 && x < 160;
          im.data[o] = inRed ? 200 : 255;
          im.data[o + 1] = inRed ? 30 : 255;
          im.data[o + 2] = inRed ? 30 : 255;
        } else {
          final inBlue = y >= 180 && y < 280 && x >= 30 && x < 170;
          im.data[o] = inBlue ? 30 : 255;
          im.data[o + 1] = inBlue ? 30 : 255;
          im.data[o + 2] = inBlue ? 200 : 255;
        }
      }
    }
    return im;
  }

  RgbaImage noGutterRaster() {
    final im = RgbaImage(width: 200, height: 300);
    for (var y = 0; y < 300; y++) {
      for (var x = 0; x < 200; x++) {
        final o = (y * 200 + x) * 4;
        im.data[o] = x * 255 ~/ 200;
        im.data[o + 1] = y * 255 ~/ 300;
        im.data[o + 2] = 128;
        im.data[o + 3] = 255;
      }
    }
    return im;
  }

  Map<String, dynamic> cfgJson(bool panel) => <String, dynamic>{
        'effects': ['parallax'],
        'fps': 24,
        'durationSec': 2.0,
        'maxDimension': 200,
        'outputFormat': 'gif',
        'seed': 7,
        if (panel) 'panelAware': true,
      };

  group('PanelSplitter：横向白带检测', () {
    test('两格图检出 2 格，内容块被格覆盖', () {
      final panels = const PanelSplitter().split(twoPanelRaster());
      expect(panels, hasLength(2));
      bool covers(PixelRect p, int y0, int y1) =>
          p.y <= y0 && p.y + p.height >= y1;
      expect(covers(panels[0], 30, 120), isTrue, reason: '上格覆盖红块');
      expect(covers(panels[1], 180, 280), isTrue, reason: '下格覆盖蓝块');
    });

    test('无白带图回退整页单格', () {
      final panels = const PanelSplitter().split(noGutterRaster());
      expect(panels, hasLength(1));
      expect(panels[0].width, 200);
      expect(panels[0].height, 300);
    });

    test('过小图直接回退', () {
      final panels = const PanelSplitter().split(RgbaImage(width: 1, height: 1));
      expect(panels, hasLength(1));
    });
  });

  group('configHash 稳定性', () {
    test('panelAware 默认不写入；true 条件写入', () {
      expect(
          EffectConfig.fromJson({'effects': ['rain']})
              .toJson()
              .containsKey('panelAware'),
          isFalse,
          reason: '默认 false 不写入 → configHash 与旧版一致');
      expect(EffectConfig.fromJson({'panelAware': true}).toJson()['panelAware'],
          true);
    });
  });

  group('管线端到端', () {
    test('多格图 panelAware 逐格分层（格数×layerCount）', () {
      final working = twoPanelRaster();
      final cfg = EffectConfig.fromJson(cfgJson(true));
      final (w, layers) = MotionPipeline(cfg).downscaleAndSplitForExport(working);
      expect(w.width, lessThanOrEqualTo(200));
      expect(layers, hasLength(6), reason: '2 格 × 3 层');
      // 每层携带格边界裁剪（画布坐标，只覆盖本格内容带）。
      final clips = layers.map((l) => l.clip).toList();
      for (var i = 0; i < layers.length; i++) {
        expect(clips[i], isNotNull, reason: 'panelAware 层必须带 clip');
      }
      // 同格 3 层 clip 相同、rank 覆盖 0..2。
      expect(clips[0], clips[1]);
      expect(clips[1], clips[2]);
      expect(clips[0]!.y, isNot(clips[3]!.y), reason: '两格 clip 不同');
      expect(layers.map((l) => l.depthRank).toSet(), {0, 1, 2});
    });

    test('白带行不串色（格边界裁剪根除跨格污染）', () {
      final cfg = EffectConfig.fromJson(cfgJson(true));
      final (working, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(twoPanelRaster());
      final frame =
          FrameCompositor(layers, working, cfg).renderFrame(0.25);
      // 白带中心行（源 y=150 → 工作分辨率等比映射）应保持纯白。
      final wy = (150 * working.height ~/ 300).clamp(0, working.height - 1);
      for (var x = 0; x < working.width; x++) {
        final o = (wy * working.width + x) * 4;
        expect(frame.data[o], greaterThanOrEqualTo(240),
            reason: '白带行红色通道保持白（x=$x）');
        expect(frame.data[o + 1], greaterThanOrEqualTo(240));
        expect(frame.data[o + 2], greaterThanOrEqualTo(240));
      }
    });

    test('单格/无白带图 on/off 逐字节等价（自动回退）', () async {
      final bytes = Uint8List.fromList(ImageIO.encodePngFrame(noGutterRaster()));
      final off = await MotionPipeline(EffectConfig.fromJson(cfgJson(false)))
          .processBytes(input: bytes);
      final on = await MotionPipeline(EffectConfig.fromJson(cfgJson(true)))
          .processBytes(input: bytes);
      expect(on.gifBytes, isNotNull);
      expect(off.gifBytes, isNotNull);
      expect(on.gifBytes, off.gifBytes,
          reason: '无白带图回退整页分层，与关闭时逐字节一致');
    });

    test('确定性：同 config 两跑逐字节一致（含 worker 并行路径）', () async {
      final bytes =
          Uint8List.fromList(ImageIO.encodePngFrame(twoPanelRaster()));
      final a = await MotionPipeline(EffectConfig.fromJson(cfgJson(true)))
          .processBytes(input: bytes);
      final b = await MotionPipeline(EffectConfig.fromJson(cfgJson(true)))
          .processBytes(input: bytes);
      expect(a.gifBytes, b.gifBytes);
    });

    test('strip 模式正交：切片后片内仍可 panelAware', () async {
      final dir = await Directory.systemTemp.createTemp('w5_strip');
      try {
        final input = '${dir.path}${Platform.pathSeparator}in.png';
        File(input).writeAsBytesSync(
            Uint8List.fromList(ImageIO.encodePngFrame(twoPanelRaster())));
        final cfg = EffectConfig.fromJson(cfgJson(true));
        final r = await processStrip(input, '${dir.path}${Platform.pathSeparator}out',
            config: cfg);
        expect(r.slices, isNotEmpty);
        // 每片独立走标准管线（panelAware 在片内生效不报错即通过）。
        for (final s in r.slices) {
          expect(s.result.configHash, isNotEmpty);
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  // ---- Task 2.3：分格叠加裁剪 + 逐格播种（panelAware）----
  //
  // 规格 §5 line 75：「所有叠加 pass ... panelAware 下：逐格播种 + 用本格 clip
  // 裁剪 ... 非 panelAware 路径逐字节不变」。裁决 R7：clip 是**新增**的原语可选
  // 参数（非 _layerClips 复用）；R8：门控 = panelAware（不看 contentAware）；
  // R9：≤1 格 → 播种/绘制走**原逐字节路径**，故 panelAware on ≡ off。
  group('分格叠加裁剪 + 逐格播种（Task 2.3）', () {
    // 逐格可见性探针：用饱和红色雨丝，白底白带若被渗漏则 G/B 通道跌破 240。
    Map<String, dynamic> rainCfg({bool panel = true, String? tier}) =>
        <String, dynamic>{
          'effects': ['parallax', 'rain'],
          'fps': 24,
          'durationSec': 2.0,
          'maxDimension': 200,
          'outputFormat': 'gif',
          'seed': 11,
          if (panel) 'panelAware': true,
          if (tier != null) 'quality': {'tier': tier},
          'rain': {'count': 400, 'opacity': 1.0, 'color': 'ff0000', 'lengthPx': 48.0},
        };

    Map<String, dynamic> snowCfg({bool panel = true}) => <String, dynamic>{
          'effects': ['parallax', 'snow'],
          'fps': 24,
          'durationSec': 2.0,
          'maxDimension': 200,
          'outputFormat': 'gif',
          'seed': 11,
          if (panel) 'panelAware': true,
          'snow': {'count': 80},
        };

    // 未被任何本格覆盖的工作行 = 白带/格间缝隙。
    Set<int> uncoveredRows(List<PixelRect> panels, int workingH) {
      final covered = <int>{};
      for (final p in panels) {
        for (var y = p.y; y < p.y + p.height; y++) {
          covered.add(y);
        }
      }
      return {for (var y = 0; y < workingH; y++) if (!covered.contains(y)) y};
    }

    // 手动搭一个「两格白底 + 红雨」场景：底与两层均纯白不透明、各自 clip 到
    // 本格（上格 y∈[0,140)、下格 y∈[160,300)），白带 y∈[140,160) 不被任何格覆盖。
    // 直接构造 FrameCompositor 而非过管线，以解耦「降采样算法随档位不同而检测
    // 到的格数不同」这一无关变量，稳定地分别验证 legacy 段路径与 AA 段路径。
    FrameCompositor rainCompositor(String? tier) {
      final cfg = EffectConfig.fromJson(rainCfg(tier: tier));
      final working = RgbaImage(width: 200, height: 300);
      working.data.fillRange(0, working.data.length, 255);
      final l0 = RgbaImage(width: 200, height: 300);
      l0.data.fillRange(0, l0.data.length, 255);
      final l1 = RgbaImage(width: 200, height: 300);
      l1.data.fillRange(0, l1.data.length, 255);
      final layers = [
        LayerImage(l0, 0, clip: PixelRect(0, 0, 200, 140)),
        LayerImage(l1, 1, clip: PixelRect(0, 160, 200, 140)),
      ];
      return FrameCompositor(layers, working, cfg);
    }

    void expectNoRainInGutter(FrameCompositor comp, String label) {
      final panels = comp.debugPanelRects();
      expect(panels.length, 2, reason: '$label：应派生 2 格');
      final rows = uncoveredRows(panels, 300);
      expect(rows, isNotEmpty, reason: '$label：格间应有未覆盖白带行');
      final frame = comp.renderFrame(0.35);
      var redAnywhere = 0;
      for (var y = 0; y < 300; y++) {
        for (var x = 0; x < 200; x++) {
          final o = (y * 200 + x) * 4;
          final r = frame.data[o], g = frame.data[o + 1], b = frame.data[o + 2];
          if (r > 150 && g < 120 && b < 120) redAnywhere++;
          if (rows.contains(y)) {
            expect(g, greaterThanOrEqualTo(240),
                reason: '$label：白带行 y=$y x=$x 绿通道应保持白（红雨不得跨格）');
            expect(b, greaterThanOrEqualTo(240),
                reason: '$label：白带行 y=$y x=$x 蓝通道应保持白');
          }
        }
      }
      expect(redAnywhere, greaterThan(50), reason: '$label：本格内应绘出红雨丝');
    }

    test('红雨 panelAware:true → 白带行零渗漏（legacy 段路径 _blendPx 加 clip）', () {
      expectNoRainInGutter(rainCompositor(null), 'legacy');
    });

    test('红雨 standard 档 → AA 段路径同样不跨白带（R7 drawSegmentAA 加 clip）', () {
      expectNoRainInGutter(rainCompositor('standard'), 'standard');
    });

    test('count∝area：较大格播种 ≥ 较小格，且每个粒子落在某格内', () {
      final cfg = EffectConfig.fromJson(snowCfg());
      final (working, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(twoPanelRaster());
      final comp = FrameCompositor(layers, working, cfg);
      final panels = comp.debugPanelRects();
      expect(panels, hasLength(2), reason: '两格页应派生 2 个 panel 矩形');
      final seeds = comp.debugParticleSeeds(EffectKind.snow);
      final w = working.width, h = working.height;
      final bucket = List<int>.filled(panels.length, 0);
      var outside = 0;
      for (final (x0, y0) in seeds) {
        final cx = x0 * w, cy = y0 * h;
        var hit = -1;
        for (var i = 0; i < panels.length; i++) {
          final p = panels[i];
          if (cx >= p.x && cx < p.x + p.width && cy >= p.y && cy < p.y + p.height) {
            hit = i;
            break;
          }
        }
        if (hit < 0) {
          outside++;
        } else {
          bucket[hit]++;
        }
      }
      expect(outside, 0, reason: '逐格播种后不应有粒子落在格间白带/格内空白之外');
      expect(bucket.fold<int>(0, (a, b) => a + b), seeds.length);
      final maxB = bucket.reduce((a, b) => a > b ? a : b);
      final minB = bucket.reduce((a, b) => a < b ? a : b);
      expect(maxB, greaterThanOrEqualTo(minB));
      // 面积∝数量：较大 panel（面积大者）计数不少于较小者。
      final areaDesc = [...panels]
        ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
      final bigIdx = panels.indexOf(areaDesc.first);
      expect(bucket[bigIdx], greaterThanOrEqualTo(
          bucket[panels.indexOf(areaDesc.last)]));
    });

    // 面积悬殊（约 3.67:1）的两格：验证播种严格按面积比而非均分。
    // 手搭不等格（splitter 对 twoPanelRaster 只会给出近等大格），
    // 直接用两个不等面积的 clip 派生 panel；total=10。
    test('count∝area 判別：面积悬殊时较大格严格过半（非均分，且余数归最大格）', () {
      final cfg = EffectConfig.fromJson(<String, dynamic>{
        'effects': ['parallax', 'snow'],
        'fps': 24,
        'durationSec': 2.0,
        'maxDimension': 200,
        'outputFormat': 'gif',
        'seed': 11,
        'panelAware': true,
        'snow': {'count': 10},
      });
      final working = RgbaImage(width: 200, height: 300)
        ..data.fillRange(0, 200 * 300 * 4, 255);
      final la = RgbaImage(width: 200, height: 300)
        ..data.fillRange(0, 200 * 300 * 4, 255);
      final lb = RgbaImage(width: 200, height: 300)
        ..data.fillRange(0, 200 * 300 * 4, 255);
      // 上大格 y∈[0,220)（面积 44000）、下小格 y∈[240,300)（面积 12000）、
      // 白带缝隙 y∈[220,240)。面积比 ≈3.67:1。
      final layers = [
        LayerImage(la, 0, clip: PixelRect(0, 0, 200, 220)),
        LayerImage(lb, 1, clip: PixelRect(0, 240, 200, 60)),
      ];
      final comp = FrameCompositor(layers, working, cfg);
      final panels = comp.debugPanelRects();
      expect(panels, hasLength(2), reason: '两个不等 clip → 派生 2 格');
      final seeds = comp.debugParticleSeeds(EffectKind.snow);
      expect(seeds.length, 10, reason: 'total 严格等于 count，逐格不增不减');
      final w = working.width, h = working.height;
      final bucket = List<int>.filled(panels.length, 0);
      var outside = 0;
      for (final (x0, y0) in seeds) {
        final cx = x0 * w, cy = y0 * h;
        var hit = -1;
        for (var i = 0; i < panels.length; i++) {
          final p = panels[i];
          if (cx >= p.x && cx < p.x + p.width &&
              cy >= p.y && cy < p.y + p.height) {
            hit = i;
            break;
          }
        }
        if (hit < 0) outside++; else bucket[hit]++;
      }
      expect(outside, 0, reason: '所有粒子落在某格内（不渗白带）');
      final area = [for (final p in panels) p.width * p.height];
      final bigIdx = area.indexOf(area.reduce((a, b) => a > b ? a : b));
      final smallIdx = 1 - bigIdx;
      // 面积悬殊 → 均分（5/5）会让较大格恰好等于半数；面积∝数量必须严格过半。
      expect(bucket[bigIdx], greaterThan(seeds.length ~/ 2),
          reason: '较大格应严格多于半数（排除均分实现）：$bucket');
      expect(bucket[bigIdx], greaterThan(bucket[smallIdx]),
          reason: '较大格计数严格大于较小格：$bucket');
      // 面积比 ≈3.67 → 大格 floor(10×0.786)=7，余数 1 归最大 → 8；小格 2。
      expect(bucket[bigIdx], greaterThanOrEqualTo(7),
          reason: '按面积比 + 余数归最大，较大格应约 8：$bucket');
    });

    test('单格/无白带图 panelAware on/off 帧逐字节等价（R9 自动回退）', () {
      final src = noGutterRaster();
      final on = EffectConfig.fromJson(snowCfg(panel: true));
      final off = EffectConfig.fromJson(snowCfg(panel: false));
      final (wo, lo) = MotionPipeline(on).downscaleAndSplitForExport(src);
      final (wf, lf) = MotionPipeline(off).downscaleAndSplitForExport(src);
      final fo = FrameCompositor(lo, wo, on).renderFrame(0.25);
      final ff = FrameCompositor(lf, wf, off).renderFrame(0.25);
      expect(wo.width, wf.width);
      expect(wo.height, wf.height);
      expect(fo.data, ff.data, reason: '无白带图回退整页，on≡off 逐字节一致');
      // 派生面板 ≤1 → 逐格路径未启用。
      expect(FrameCompositor(lo, wo, on).debugPanelRects().length, lessThanOrEqualTo(1));
    });

    test('确定性：同 panelAware:true config 两跑逐字节一致', () {
      final cfg = EffectConfig.fromJson(rainCfg());
      final (working, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(twoPanelRaster());
      final a = FrameCompositor(layers, working, cfg).renderFrame(0.5);
      final b = FrameCompositor(layers, working, cfg).renderFrame(0.5);
      expect(a.data, b.data);
    });
  });
}
