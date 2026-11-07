import 'dart:convert';
import 'dart:io';

/// A separate process is required: POSIX advisory locks are associated with the process, not the Dart isolate.
Future<void> main(List<String> arguments) async {
  final handle = File('${arguments.single}.lock').openSync(mode: FileMode.append);
  try {
    handle.lockSync(FileLock.exclusive, 0, 1);
    stdout.writeln('locked');
    await stdout.flush();
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  } finally {
    handle.closeSync();
  }
}
