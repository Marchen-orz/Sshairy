import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Application support directory, resolved in main() before the app starts.
final dataDirProvider = Provider<String>((_) => throw UnimplementedError());

const _flag = '--data-dir';
const _environmentKey = 'SSHAIRY_DATA_DIR';

/// The data directory requested on the command line or in the environment, if any.
///
/// A development build resolves the same application support directory as an
/// installed copy, which would make both write the same hosts, settings and
/// logs. Passing `--data-dir=<path>` (or setting `SSHAIRY_DATA_DIR`) keeps a
/// development instance on its own state. Null keeps the platform default.
String? dataDirOverride(List<String> arguments, Map<String, String> environment) {
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument.startsWith('$_flag=')) {
      final path = argument.substring(_flag.length + 1);
      if (path.isNotEmpty) return path;
    } else if (argument == _flag && index + 1 < arguments.length) {
      final path = arguments[index + 1];
      if (path.isNotEmpty) return path;
    }
  }
  final path = environment[_environmentKey];
  return path != null && path.isNotEmpty ? path : null;
}
