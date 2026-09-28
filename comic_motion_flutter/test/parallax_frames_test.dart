// 交互帧集加载测试（index.json 解析 + 帧组装，内存回调，无磁盘依赖）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_flutter/src/parallax_frames.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pkg_img;

/// 构造最小合法 PNG 字节（1×1 红点，颜色即内容指纹）。
Uint8List png1x1(int r, int g, int b) {
  final img = pkg_img.Image(width: 1, height: 1, numChannels: 3)
    ..setPixelRgb(0, 0, r, g, b);
  return Uint8List.fromList(pkg_img.encodePng(img).toList());
}

/// 与核心包导出格式一致的 index.json 字节。
Uint8List indexJson({
  String kind = 'interactive',
  required List<Map<String, Object>> sets,
}) {
  return Uint8List.fromList(
    utf8.encode(const JsonEncoder().convert({'kind': kind, 'sets': sets})),
  );
}

void main() {
  test('单轴 index.json → 1 组帧集，axis/phases/帧字节对齐', () async {
    final f0 = png1x1(255, 0, 0);
    final f1 = png1x1(0, 255, 0);
    final f2 = png1x1(0, 0, 255);
    final bytes = indexJson(sets: [
      {
        'axis': 'horizontal',
        'phases': [-1.0, 0.0, 1.0],
        'frames': ['frame_0000.png', 'frame_0001.png', 'frame_0002.png'],
      }
    ]);

    final sets = await loadInteractionSetsFromIndexJson(
      bytes,
      loadFrame: (file) async => switch (file) {
        'frame_0000.png' => f0,
        'frame_0001.png' => f1,
        'frame_0002.png' => f2,
        _ => throw StateError('unexpected $file'),
      },
    );

    expect(sets, hasLength(1));
    final s = sets.single;
    expect(s.axis, InteractionAxis.horizontal);
    expect(s.phases, [-1.0, 0.0, 1.0]);
    expect(s.pngBytes, hasLength(3));
    expect(identical(s.pngBytes[0], f0), isTrue);
    expect(identical(s.pngBytes[2], f2), isTrue);
  });

  test('both 产物 → 按索引顺序返回水平、垂直两组', () async {
    final bytes = indexJson(sets: [
      {
        'axis': 'horizontal',
        'phases': [-1.0, 1.0],
        'frames': ['h0.png', 'h1.png'],
      },
      {
        'axis': 'vertical',
        'phases': [-1.0, 1.0],
        'frames': ['v0.png', 'v1.png'],
      },
    ]);
    final pool = {
      'h0.png': png1x1(1, 0, 0),
      'h1.png': png1x1(2, 0, 0),
      'v0.png': png1x1(0, 1, 0),
      'v1.png': png1x1(0, 2, 0),
    };
    final sets = await loadInteractionSetsFromIndexJson(
      bytes,
      loadFrame: (f) async => pool[f]!,
    );
    expect(sets, hasLength(2));
    expect(sets[0].axis, InteractionAxis.horizontal);
    expect(sets[1].axis, InteractionAxis.vertical);
  });

  test('kind 非 interactive 抛 ArgumentError', () async {
    final bytes = indexJson(
      kind: 'entrance',
      sets: [
        {
          'axis': 'horizontal',
          'phases': [0.0],
          'frames': ['a.png'],
        }
      ],
    );
    await expectLater(
      loadInteractionSetsFromIndexJson(bytes, loadFrame: (f) async => f0),
      throwsArgumentError,
    );
  });

  test('未知 axis 抛 ArgumentError', () async {
    final bytes = indexJson(sets: [
      {
        'axis': 'diagonal',
        'phases': [0.0],
        'frames': ['a.png'],
      }
    ]);
    await expectLater(
      loadInteractionSetsFromIndexJson(bytes, loadFrame: (f) async => f0),
      throwsArgumentError,
    );
  });

  test('帧数与 phases 数不一致抛 ArgumentError', () async {
    final bytes = indexJson(sets: [
      {
        'axis': 'horizontal',
        'phases': [-1.0, 0.0, 1.0],
        'frames': ['a.png', 'b.png'],
      }
    ]);
    await expectLater(
      loadInteractionSetsFromIndexJson(bytes, loadFrame: (f) async => f0),
      throwsArgumentError,
    );
  });
}

final Uint8List f0 = png1x1(9, 9, 9);
