import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:comic_motion_flutter/reader.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String json) => Uint8List.fromList(utf8.encode(json));

void main() {
  test('解析合法清单并回填默认值', () {
    final m = PanelManifest.fromBytes(_bytes('''
{
  "kind": "comic_panels",
  "version": 1,
  "panels": [
    {"id": "a", "rect": [0.1, 0.2, 0.4, 0.6]},
    {
      "id": "b",
      "rect": [0.5, 0.1, 0.9, 0.5],
      "reveal": "fade",
      "dim": 0.3,
      "glow": 0.1,
      "scale": 1.02,
      "clip": {"asset": "b.gif", "loop": false}
    }
  ]
}
'''));

    expect(m.version, 1);
    expect(m.panels, hasLength(2));
    expect(m.panels.first.reveal, PanelReveal.tear);
    expect(m.panels.first.dim, 0.42);
    expect(m.panels.first.glow, 0.22);
    expect(m.panels.first.scale, 1.012);
    expect(m.panels.first.clip, isNull);
    expect(m.panels.last.reveal, PanelReveal.fade);
    expect(m.panels.last.clip!.asset, 'b.gif');
    expect(m.panels.last.clip!.loop, isFalse);
  });

  test('toJson 与 fromJson 往返一致', () {
    final m = PanelManifest.fromJson(<String, dynamic>{
      'kind': PanelManifest.kind,
      'version': PanelManifest.currentVersion,
      'panels': [
        {
          'id': 'p',
          'rect': <num>[0.1, 0.2, 0.4, 0.6],
          'reveal': 'tear',
          'dim': 0.4,
          'glow': 0.2,
          'scale': 1.01,
          'clip': {'asset': 'p.gif', 'loop': true},
        },
      ],
    });
    final again = PanelManifest.fromJson(m.toJson());
    expect(again.panels.single.id, 'p');
    expect(again.panels.single.rect, const Rect.fromLTRB(0.1, 0.2, 0.4, 0.6));
    expect(again.panels.single.clip!.asset, 'p.gif');
  });

  test('kind 错误直接失败', () {
    expect(
      () => PanelManifest.fromJson(<String, dynamic>{
        'kind': 'other',
        'version': 1,
        'panels': [
          {
            'id': 'a',
            'rect': <num>[0.1, 0.1, 0.2, 0.2],
          },
        ],
      }),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('不支持的 version 直接失败', () {
    expect(
      () => PanelManifest.fromJson(<String, dynamic>{
        'kind': PanelManifest.kind,
        'version': 2,
        'panels': [
          {
            'id': 'a',
            'rect': <num>[0.1, 0.1, 0.2, 0.2],
          },
        ],
      }),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('panels 为空直接失败', () {
    expect(
      () => PanelManifest.fromJson(<String, dynamic>{
        'kind': PanelManifest.kind,
        'version': 1,
        'panels': <Object>[],
      }),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('id 重复直接失败', () {
    expect(
      () => PanelManifest.fromJson(<String, dynamic>{
        'kind': PanelManifest.kind,
        'version': 1,
        'panels': [
          {
            'id': 'a',
            'rect': <num>[0.1, 0.1, 0.2, 0.2],
          },
          {
            'id': 'a',
            'rect': <num>[0.3, 0.3, 0.4, 0.4],
          },
        ],
      }),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('rect 顺序、范围与长度校验', () {
    Object invalid(List<num> rect) => <String, dynamic>{
          'kind': PanelManifest.kind,
          'version': 1,
          'panels': [
            {'id': 'a', 'rect': rect},
          ],
        };
    for (final rect in <List<num>>[
      <num>[0.5, 0.1, 0.4, 0.2],
      <num>[0.1, 0.5, 0.2, 0.4],
      <num>[-0.1, 0.1, 0.2, 0.2],
      <num>[0.1, 0.1, 1.2, 0.2],
      <num>[0.1, 0.1, 0.2],
    ]) {
      expect(() => PanelManifest.fromJson(invalid(rect)),
          throwsA(isA<ArgumentError>()),
          reason: 'rect=$rect');
    }
  });

  test('reveal 非法直接失败', () {
    expect(
      () => PanelManifest.fromJson(<String, dynamic>{
        'kind': PanelManifest.kind,
        'version': 1,
        'panels': [
          {
            'id': 'a',
            'rect': <num>[0.1, 0.1, 0.2, 0.2],
            'reveal': 'explode',
          },
        ],
      }),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('样式参数越界直接失败', () {
    for (final patch in <Map<String, dynamic>>[
      {'dim': 1.1},
      {'glow': -0.1},
      {'scale': 0.99},
      {'scale': 1.3},
    ]) {
      expect(
        () => PanelManifest.fromJson(<String, dynamic>{
          'kind': PanelManifest.kind,
          'version': 1,
          'panels': [
            {
              'id': 'a',
              'rect': <num>[0.1, 0.1, 0.2, 0.2],
              ...patch,
            },
          ],
        }),
        throwsA(isA<ArgumentError>()),
        reason: 'patch=$patch',
      );
    }
  });

  test('clip.asset 缺失直接失败', () {
    expect(
      () => PanelManifest.fromJson(<String, dynamic>{
        'kind': PanelManifest.kind,
        'version': 1,
        'panels': [
          {
            'id': 'a',
            'rect': <num>[0.1, 0.1, 0.2, 0.2],
            'clip': <String, dynamic>{'loop': true},
          },
        ],
      }),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('加载器按面板 id 收集素材且同一素材只读一次', () async {
    final calls = <String>[];
    final loaded = await loadPanelManifest(
      _bytes('''
{
  "kind": "comic_panels",
  "version": 1,
  "panels": [
    {"id": "a", "rect": [0.1, 0.1, 0.4, 0.4],
     "clip": {"asset": "same.gif"}},
    {"id": "b", "rect": [0.5, 0.1, 0.9, 0.4],
     "clip": {"asset": "same.gif"}},
    {"id": "c", "rect": [0.1, 0.5, 0.9, 0.9]}
  ]
}
'''),
      loadClip: (asset) async {
        calls.add(asset);
        return Uint8List.fromList(<int>[asset.length]);
      },
    );
    expect(calls, <String>['same.gif']);
    expect(loaded.clips.keys, containsAll(<String>['a', 'b']));
    expect(loaded.clips['a'], Uint8List.fromList(<int>[8]));
  });
}
