import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// Plan B Task 4：`handMotion` 效果注册 + `HandMotionParams` 序列化锁步。
///
/// 核心红线：**未启用时参数绝不进 JSON ⇒ 出厂 configHash 基线一字不动**
/// （因此本任务不需要 re-baseline）。序列化门控沿用 v1.1/v1.3 的
/// 「`effects.contains(kind)` 才写这一段」习语。
///
/// 参数面只有 `ampDeg`/`periodSec`：本期部件只来自 `part_motion.json`，
/// 置信度阈值这类没有消费者的旋钮不进契约（用户裁决 + YAGNI）。
void main() {
  // 两个默认值是本任务的锚点（另一源 = 文档口径，见 README 动效目录行）。
  const defAmpDeg = 8.0;
  const defPeriodSec = 2.0;

  List<EffectKind> withHand() =>
      [...EffectConfig().effects, EffectKind.handMotion];

  group('HandMotionParams 多源锁步', () {
    test('构造默认 == fromJson 缺键 == fromJson 显式 null', () {
      const ctor = HandMotionParams();
      final empty = HandMotionParams.fromJson(const {});
      final nulls =
          HandMotionParams.fromJson(const {'ampDeg': null, 'periodSec': null});
      for (final p in [ctor, empty, nulls]) {
        expect(p.ampDeg, defAmpDeg, reason: 'ampDeg 三源必须同锚点');
        expect(p.periodSec, defPeriodSec, reason: 'periodSec 三源必须同锚点');
      }
    });

    test('toJson 键集合恰为两参数（无消费者的旋钮不许进契约）', () {
      expect(const HandMotionParams().toJson().keys.toList(),
          containsAllInOrder(['ampDeg', 'periodSec']));
    });

    test('显式值经 toJson→fromJson 逐字段保真', () {
      const loud = HandMotionParams(ampDeg: 14.5, periodSec: 3.0);
      final back = HandMotionParams.fromJson(loud.toJson());
      expect(back.ampDeg, 14.5);
      expect(back.periodSec, 3.0);
    });
  });

  group('EffectKind.handMotion 注册', () {
    test('effectKindFromName 认名，未知名仍抛', () {
      expect(effectKindFromName('handMotion'), EffectKind.handMotion);
      expect(EffectKind.handMotion.name, 'handMotion');
      expect(
          () => effectKindFromName('handmotion'), throwsA(isA<Exception>()));
    });

    test('kEffectNames 与枚举同源且含 handMotion', () {
      expect(kEffectNames.length, EffectKind.values.length);
      expect(kEffectNames, contains('handMotion'));
    });

    test('目录文案里的「N 种」与枚举长度同源', () {
      final spec = kRenderParamSpecs.firstWhere((s) => s.name == 'effects');
      final declared = RegExp(r'（(\d+)\s*种）').firstMatch(spec.description)!;
      expect(int.parse(declared.group(1)!), EffectKind.values.length,
          reason: 'param_catalog 的「N 种」是锁步源，改枚举必须改文案');
    });

    test('handMotion 不是条漫安全效果（切片会截断手部多边形）', () {
      expect(kStripSafeEffects.contains(EffectKind.handMotion), isFalse);
    });
  });

  group('门控序列化：哈希基线不动', () {
    test('出厂默认 JSON 不含 handMotion 段', () {
      expect(EffectConfig().toJson().containsKey('handMotion'), isFalse,
          reason: '默认效果集不含 handMotion ⇒ 该段必须整段省略');
    });

    test('未启用时改参数不进 JSON、也不进 configHash', () {
      final base = EffectConfig();
      final loud =
          EffectConfig(handMotion: const HandMotionParams(ampDeg: 30));
      expect(loud.toJson().containsKey('handMotion'), isFalse);
      expect(loud.configHash, base.configHash,
          reason: '门控失效 ⇒ 出厂基线会被无声推走（需要 re-baseline，本任务禁止）');
    });

    test('启用才写段，且参数变化会改变哈希', () {
      final on = EffectConfig(effects: withHand());
      expect(on.toJson().containsKey('handMotion'), isTrue);
      expect(on.configHash, isNot(EffectConfig().configHash));

      final louder = EffectConfig(
          effects: withHand(),
          handMotion: const HandMotionParams(ampDeg: 12));
      expect(louder.configHash, isNot(on.configHash),
          reason: '启用后 ampDeg 必须是活的参数');
    });

    test('EffectConfig 整份 round-trip 保真（含省略路径）', () {
      final src = EffectConfig(
        effects: withHand(),
        handMotion: const HandMotionParams(ampDeg: 11.0, periodSec: 2.5),
      );
      final back = EffectConfig.fromJson(src.toJson());
      expect(back.handMotion.ampDeg, 11.0);
      expect(back.handMotion.periodSec, 2.5);
      expect(back.configHash, src.configHash);

      // 省略路径：默认配置的 JSON 里没有该段 ⇒ 回落构造默认，而不是崩溃。
      final omitted = EffectConfig.fromJson(EffectConfig().toJson());
      expect(omitted.handMotion.ampDeg, defAmpDeg);
      expect(omitted.effects.contains(EffectKind.handMotion), isFalse);
    });

    test('copy() 带走 handMotion 参数与效果开关', () {
      final src = EffectConfig(
          effects: withHand(),
          handMotion: const HandMotionParams(ampDeg: 9.0));
      final c = src.copy();
      expect(c.effects.contains(EffectKind.handMotion), isTrue);
      expect(c.handMotion.ampDeg, 9.0);
      expect(c.configHash, src.configHash);
    });
  });
}
