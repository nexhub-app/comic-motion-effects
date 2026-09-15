import 'package:comic_motion/src/cli.dart' as cli;

/// Executable entrypoint: `dart run bin/comic_motion.dart <command> [args]`
Future<void> main(List<String> args) async {
  await cli.main(args);
}
