import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// W5：分格感知分层 —— 横向白带检测、逐格独立分层、格边界裁剪。
///
/// 红线锚点：v1.4 R39 起 panelAware **默认开启**——默认命中省略哨兵故仍不写
/// 序列化键（默认 configHash 键集不动），显式 `false` 才写键；单格/无白带图
/// on/off 逐字节等价（自动回退，这条是 R39 用户裁决时要求保留的保护）；多格图
/// 白带行不串色（格边界裁剪）；并行（worker 携带 ranks/clips）与串行产物一致；
/// 确定性。反相奇偶取自 depthRank 而非扁平层下标（F2，见 engine_test 3.6d 组）。
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

  // Task 3.6 R28：分格 fixture 做成**与档位无关** —— twoPanelRaster 最长边 300，
  // maxDimension 取 300 ⇒ 两档都不降采样。降采样算法随档位不同（standard 面积
  // 平均 vs legacy 最近邻），缩到 200 会把 20px 白带抹到检不出 2 格，那是降采样
  // 边际效应而不是分格逻辑；把上限抬到不缩放，两条档位的分格断言才都在跑。
  Map<String, dynamic> cfgJson(bool panel) => <String, dynamic>{
        'effects': ['parallax'],
        'fps': 24,
        'durationSec': 2.0,
        'maxDimension': 300,
        'outputFormat': 'gif',
        'seed': 7,
        // R39：默认已翻成 true ⇒ 「关」必须**显式写 false** 才达。沿用旧的
        // `if (panel) 'panelAware': true` 会让 panel:false 落进缺键分支、
        // 被兜底成 true —— 本文件的 on/off 对照用例当场变成 on≡on 的空门。
        if (!panel) 'panelAware': false,
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

  group('序列化形状 + 新默认真的进管线（R39）', () {
    // 出厂默认配置（一个 panelAware 键都不传）——本组一切以它为准。
    Map<String, dynamic> defaultCfgJson() => <String, dynamic>{
          'effects': ['parallax'],
          'fps': 24,
          'durationSec': 2.0,
          'maxDimension': 300,
          'outputFormat': 'gif',
          'seed': 7,
        };

    test('默认 true 命中省略哨兵 ⇒ 默认 JSON 不写键；false 才写', () {
      final def = EffectConfig.fromJson({'effects': ['rain']});
      expect(def.panelAware, isTrue, reason: 'R39：出厂默认开启分格感知');
      expect(def.toJson().containsKey('panelAware'), isFalse,
          reason: '默认 == 省略哨兵 ⇒ 默认 JSON 键集与翻转前逐字节相同'
              '（旧客户端不受影响，configHash 不因此移动）');
      expect(EffectConfig(panelAware: true).toJson().containsKey('panelAware'),
          isFalse, reason: '显式 true 与新默认同形（不写键）');
      expect(EffectConfig(panelAware: false).toJson()['panelAware'], false,
          reason: '回滚意图必须序列化（否则缺键兜底成 true 静默改写用户配置）');
    });

    test('行为门：不传 panelAware 的多格页真的逐格分层（默认不是摆设）', () {
      // 形状门只证明「JSON 里没写这个键」；本门证明新默认**走到了管线**。
      // 少了它，翻一个默认值可以形状全对而渲染路径一动不动——正是
      // 投诉 #2 里「默认等于没开」的那个失效模式。
      final cfg = EffectConfig.fromJson(defaultCfgJson());
      expect(cfg.panelAware, isTrue);
      expect(cfg.configHash,
          EffectConfig.fromJson({...defaultCfgJson(), 'panelAware': true})
              .configHash,
          reason: '显式 true == 不传（R5 便捷参数契约）');
      final (w, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(twoPanelRaster());
      expect(layers.length, 2 * cfg.layerCount,
          reason: '两格页必须格数 × layerCount 层（panelAware 生效）');
      expect(layers.every((l) => l.clip != null), isTrue,
          reason: '每层携带格边界 clip');
      expect(FrameCompositor(layers, w, cfg).debugPanelRects().length, 2,
          reason: '合成器派生出 2 格，而不是整页回退');

      // 同一扇门走**构造默认**（不经 JSON）。上面的形状门钉 toJson、本门钉
      // ctor 那一侧：三处锁步（ctor / 省略哨兵 / 缺键兜底）任一处漂移，
      // 这里立刻与 JSON 门意见不一致而红。
      final bare =
          EffectConfig(effects: const [EffectKind.parallax], maxDimension: 300);
      expect(bare.panelAware, isTrue, reason: 'ctor 默认必须与缺键兜底同值');
      final (bw, blayers) =
          MotionPipeline(bare).downscaleAndSplitForExport(twoPanelRaster());
      expect(blayers.length, 2 * bare.layerCount,
          reason: '不经 JSON 的默认同样逐格分层（R39 开箱生效）');
      expect(FrameCompositor(blayers, bw, bare).debugPanelRects().length, 2,
          reason: '构造默认路径同样派生 2 格');
    });

    test('回退门在新默认下仍成立：无白带图自动整页分层（≤1 格）', () {
      // 这是用户裁决 R39 时明确要求保留的保护：单格 / 大留白页不得被误分格。
      final cfg = EffectConfig.fromJson(defaultCfgJson());
      final (w, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(noGutterRaster());
      expect(layers.length, cfg.layerCount, reason: '检不出 ≥2 格 ⇒ 整页分层');
      expect(
          FrameCompositor(layers, w, cfg).debugPanelRects().length,
          lessThanOrEqualTo(1),
          reason: '逐格路径未启用 ⇒ 与 panelAware:false 逐字节等价（R9）');
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
          // 同 cfgJson：300 ⇒ 两档都不降采样，分格断言与档位无关（R28）。
          'maxDimension': 300,
          'outputFormat': 'gif',
          'seed': 11,
          // R39：同 cfgJson——「关」要显式写 false，缺键现在是「开」。
          if (!panel) 'panelAware': false,
          if (tier != null) 'quality': {'tier': tier},
          'rain': {'count': 400, 'opacity': 1.0, 'color': 'ff0000', 'lengthPx': 48.0},
        };

    Map<String, dynamic> snowCfg({bool panel = true}) => <String, dynamic>{
          'effects': ['parallax', 'snow'],
          'fps': 24,
          'durationSec': 2.0,
          'maxDimension': 300,
          'outputFormat': 'gif',
          'seed': 11,
          // R39：同 cfgJson——「关」要显式写 false，缺键现在是「开」。
          if (!panel) 'panelAware': false,
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
      // Task 3.6：缺 quality 段的 JSON 现在解析成 standard（R24 锁步）⇒
      // 「legacy 段路径」必须显式钉 tier=legacy，标签才诚实；AA 段路径由
      // 下一条显式 standard 的用例覆盖，两档覆盖都没有掉。
      expectNoRainInGutter(rainCompositor('legacy'), 'legacy');
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

  // ---- Task 3.6 修复轮 finding 2：panelAware 在**必须降采样**的形状上、
  // 跑的是 R32 新默认档（standard 面积平均）通路时仍要检出 ≥2 格。
  //
  // 既有分格用例（R28）为了「两档都不降采样」把 maxDimension 抬到 300，于是
  // 「降采样 + 分格」这条真实导出主路径一直没有覆盖：漫画页原图普遍 1600–2400
  // 高，导出必然降采样。这里补的正是那条路径，并且**不写 quality 段**（默认档
  // 即 standard，R32），用断言把「跑的是面积平均」钉住。
  //
  // 形状覆盖两种缩放比：精确整数 2×（1920×2400 → 960×1200）与非整数 1.5×
  // （1920×2400 → 1280×1600，真实导出上限）。后者历史上是**失败**的：
  // `_areaAxisX/_areaAxisY` 把窗口末纹素算成 `(a + scale - 1).floor()`，比正确
  // 值 `(a + scale).ceil() - 1` 少一根，加权只覆盖到 floor(b) 却仍按 scale 归一，
  // 纯白被压成交替的 113/170 ⇒ 白带行的近白占比跌破 whiteRatio 0.90 → 检不出
  // 分格（整数比恰好不受影响，所以前一条用例一直是绿的）。R33 已修：两条用例
  // 现在都跑在真实导出主路径上；平场不变量本身由 `render_test.dart` 的
  // 「boxDownscale 平场不变量」门直接钉住。
  group('降采样 + panelAware 在新默认档下仍分格（修复轮 finding 2）', () {
    /// w×h 两格竖排页：中央 [h/2 - gutter/2, +gutter) 纯白带，上下格各一块
    /// 深色内容（四周留 inset 纸白边）。与 twoPanelRaster 同构，只是可参数化尺寸。
    RgbaImage pageRaster(int w, int h, int gutter, int inset) {
      final im = RgbaImage(width: w, height: h);
      final mid = h ~/ 2;
      final top = mid - (gutter / 2).round();
      final bot = top + gutter;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          im.data[o + 3] = 255;
          var r = 255, g = 255, b = 255;
          if (y >= top && y < bot) {
            // 白带（分隔带）
          } else if (y < top) {
            if (y >= inset && y < top - inset && x >= inset && x < w - inset) {
              r = 200;
              g = 30;
              b = 30;
            }
          } else {
            if (y >= bot + inset &&
                y < h - inset &&
                x >= inset &&
                x < w - inset) {
              r = 30;
              g = 30;
              b = 200;
            }
          }
          im.data[o] = r;
          im.data[o + 1] = g;
          im.data[o + 2] = b;
        }
      }
      return im;
    }

    Map<String, dynamic> pageCfg(int maxDim) => <String, dynamic>{
          'effects': ['parallax'],
          'fps': 24,
          'durationSec': 2.0,
          'maxDimension': maxDim,
          'outputFormat': 'gif',
          'seed': 7,
          'panelAware': true,
        };

    test('默认档（R32 standard）+ 必然降采样 2×：1920×2400 页仍检出 2 格、逐格分层', () {
      final cfg = EffectConfig.fromJson(pageCfg(1200));
      expect(cfg.toJson().containsKey('quality'), isFalse,
          reason: '本例不给 quality 段 ⇒ 走 R32 新默认');
      expect(cfg.quality.tier, RenderTier.standard,
          reason: '断言跑的是 standard（面积平均）通路，不是 legacy 双线性');
      final src = pageRaster(1920, 2400, 30, 120);
      final (working, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(src);
      expect('${working.width}x${working.height}', '960x1200',
          reason: '必须真的降采样（否则与既有不缩放用例重复）');
      expect(const PanelSplitter().split(working), hasLength(2));
      final rects = FrameCompositor(layers, working, cfg).debugPanelRects();
      expect(rects, hasLength(2), reason: '降采样后仍要派生 2 个 panel 矩形');
      expect(layers, hasLength(6), reason: '2 格 × 3 层；回退整页只有 3 层');
      // 白带在工作分辨率仍是白带（面积平均在整数比下精确保持纯白）。
      final gy = working.height ~/ 2;
      for (final x in [0, working.width ~/ 2, working.width - 1]) {
        final o = (gy * working.width + x) * 4;
        expect(working.data[o], 255, reason: '白带 x=$x 红通道');
        expect(working.data[o + 1], 255);
        expect(working.data[o + 2], 255);
      }
    });

    test('同形状 maxDimension 1600（非整数比 1.5×）默认档也必须检出 2 格', () {
      // finding 2 的真实导出形状：原页 1920×2400、导出上限 1600 ⇒ 缩放比 1.5。
      // R33 之前这里必然退化（working=1280x1600 的白带被面积平均压成 113/170 →
      // PanelSplitter 1 格、debugPanelRects 0 个、层退化成 3），当时以 skip 记账；
      // 修好 `_areaAxisX/_areaAxisY` 的窗口末纹素后本例转绿，且断言一句未放宽：
      // 仍是 2 格 / 2 个矩形 / 6 层（2 格 × 3 层），白带 30px、形状不换。
      // 显式 tier=legacy 在同一形状从来是 2 格（双线性不做面积平均，不受影响）。
      final cfg = EffectConfig.fromJson(pageCfg(1600));
      expect(cfg.quality.tier, RenderTier.standard);
      final src = pageRaster(1920, 2400, 30, 120);
      final (working, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(src);
      expect(working.width, 1280);
      expect(working.height, 1600);
      expect(const PanelSplitter().split(working), hasLength(2),
          reason: '1.5× 面积平均必须保持纯白 DC（否则白带检不出 ⇒ 退化整页）');
      expect(
          FrameCompositor(layers, working, cfg).debugPanelRects(), hasLength(2));
      expect(layers, hasLength(6));
    });
  });
}
