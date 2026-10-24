import 'dart:io';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

/// 推理会话接缝：把 onnxruntime_v2 的具体类型隔离在本文件，单元测试用
/// 假会话锁定张量布局、归一化与后处理。
abstract class DepthSession {
  /// [input] 为 NCHW float32（shape 如 `[1,3,256,256]`），返回单一输出
  /// 张量的展平值（H×W 个元素）。
  List<double> run(Float32List input, List<int> shape);
}

/// 生产适配器：薄封装 OrtSession。会话必须在目标 isolate 内创建。
class OrtSessionAdapter implements DepthSession {
  OrtSessionAdapter._(
      this._session, this._runOptions, this._inputName, this._outputName);

  final OrtSession _session;
  final OrtRunOptions _runOptions;
  final String _inputName;
  final String _outputName;

  factory OrtSessionAdapter.fromBytes(Uint8List modelBytes) {
    OrtEnv.instance.init();
    final session =
        OrtSession.fromBuffer(modelBytes, OrtSessionOptions());
    return OrtSessionAdapter._(session, OrtRunOptions(),
        session.inputNames.first, session.outputNames.first);
  }

  factory OrtSessionAdapter.fromFile(String path) =>
      OrtSessionAdapter.fromBytes(File(path).readAsBytesSync());

  @override
  List<double> run(Float32List input, List<int> shape) {
    final tensor = OrtValueTensor.createTensorWithDataList(input, shape);
    final out =
        _session.run(_runOptions, <String, OrtValue>{_inputName: tensor},
            <String>[_outputName]);
    final values = _flatten(out[0]!.value);
    for (final v in out) {
      v?.release();
    }
    tensor.release();
    return values;
  }

  static List<double> _flatten(dynamic value) {
    final out = <double>[];
    void walk(dynamic node) {
      if (node is List) {
        for (final child in node) {
          walk(child);
        }
      } else if (node is num) {
        out.add(node.toDouble());
      }
    }

    walk(value);
    return out;
  }
}

/// MiDaS v2.1 small 256 估算器（QDQ int8 模型同布局）。预处理/后处理与
/// 已验收的端到端探针逐行对应（探针: build/depth_probe/onnx_probe）。
/// 本类不持有 OrtEnv 之外的任何全局状态；会话生命周期由宿主经
/// [DepthSession] 的实际实现管理（每次管线运行一个实例即可）。
class OnnxDepthEstimator implements DepthEstimator {
  OnnxDepthEstimator(this.session, {this.size = 256});

  final DepthSession session;

  /// 模型输入边长（正方形）。默认 256 = midas_v21_small_256。
  final int size;

  @override
  DepthMap estimate(RgbaImage img) {
    final s = size;
    final input = Float32List(3 * s * s);
    // 双线性缩放 + ImageNet 归一化，NCHW。
    final sx = img.width / s, sy = img.height / s;
    const mean = <double>[0.485, 0.456, 0.406];
    const std = <double>[0.229, 0.224, 0.225];
    final px = List<int>.filled(4, 0);
    for (var y = 0; y < s; y++) {
      for (var x = 0; x < s; x++) {
        img.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, px);
        input[0 * s * s + y * s + x] = (px[0] / 255.0 - mean[0]) / std[0];
        input[1 * s * s + y * s + x] = (px[1] / 255.0 - mean[1]) / std[1];
        input[2 * s * s + y * s + x] = (px[2] / 255.0 - mean[2]) / std[2];
      }
    }
    final depth = session.run(input, <int>[1, 3, s, s]);
    if (depth.length != s * s) {
      throw StateError('unexpected depth size ${depth.length} != ${s * s}');
    }
    double lo = depth[0], hi = depth[0];
    for (final v in depth) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final range = hi - lo <= 1e-6 ? 1.0 : hi - lo;
    final values = List<double>.generate(
        depth.length, (int i) => (depth[i] - lo) / range);
    return DepthMap(s, s)..data.setAll(0, values);
  }
}
