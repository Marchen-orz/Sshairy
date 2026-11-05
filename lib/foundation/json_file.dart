import 'dart:convert';
import 'dart:io';

/// A JSON document on disk: writes are serialized and replace the file atomically.
class JsonFile {
  JsonFile(this.path);

  final String path;
  Future<void> _pending = Future.value();

  /// Returns null when missing. An unreadable file is kept aside rather than overwritten.
  Map<String, dynamic>? read() {
    final file = File(path);
    if (!file.existsSync()) return null;
    final text = file.readAsStringSync();
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      file.renameSync('$path.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      return null;
    }
  }

  Future<void> write(Map<String, dynamic> data) {
    final next = _pending.then((_) async {
      final tmp = File('$path.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
      await tmp.rename(path);
    });
    _pending = next.catchError((_) {});
    return next;
  }
}
