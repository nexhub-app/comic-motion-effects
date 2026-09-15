import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as pkg;
void main(List<String> args) {
  for (final p in args) {
    final bytes = Uint8List.fromList(File(p).readAsBytesSync());
    final dec = pkg.GifDecoder(bytes);
    final n = dec.info?.numFrames ?? -1;
    final f0 = dec.decodeFrame(0);
    var rs = 0, gs = 0, bs = 0, cnt = 0;
    if (f0 != null) {
      for (var y = 0; y < f0.height; y += 8) {
        for (var x = 0; x < f0.width; x += 8) {
          final c = f0.getPixel(x, y);
          rs += c.r.toInt(); gs += c.g.toInt(); bs += c.b.toInt(); cnt++;
        }
      }
    }
    stdout.writeln('$p frames=$n first=${f0?.width}x${f0?.height} avgRGB=${(rs/cnt).toStringAsFixed(0)}/${(gs/cnt).toStringAsFixed(0)}/${(bs/cnt).toStringAsFixed(0)}');
  }
}
