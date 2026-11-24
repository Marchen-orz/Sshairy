import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

/// The secrets file flutter_secure_storage_windows 4.x keeps: one JSON object of strings, protected with DPAPI for the
/// current user. Unlike the plugin, a file that cannot be read or decrypted is an error rather than an empty store and
/// is never deleted, and a write replaces it through a temporary file (docs/DESIGN.md ADR-16).
class WindowsSecretFile {
  WindowsSecretFile(Future<String> Function() locate, {this.retries = _retries}) : _locate = locate;

  /// The plugin's location, so secrets saved before ADR-16 stay readable without a migration.
  WindowsSecretFile.shared()
    : this(() async => '${(await getApplicationSupportDirectory()).path}\\flutter_secure_storage.dat');

  static const _retries = [
    Duration(milliseconds: 50),
    Duration(milliseconds: 150),
    Duration(milliseconds: 400),
    Duration(seconds: 1),
  ];

  /// Waits before each retry while something else (often antivirus) briefly holds the file.
  final List<Duration> retries;
  final Future<String> Function() _locate;
  late final Future<String> _path = _locate();
  Future<void> _queue = Future.value();

  Future<String?> read(String key) => _serial(() async => (await _load())[key]);

  Future<void> write(String key, String value) => _serial(() async {
    final secrets = await _load();
    secrets[key] = value;
    await _save(secrets);
  });

  Future<void> delete(String key) => _serial(() async {
    final secrets = await _load();
    if (secrets.remove(key) != null) await _save(secrets);
  });

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<Map<String, String>> _load() async {
    final file = File(await _path);
    final encrypted = await _retry(() async => await file.exists() ? await file.readAsBytes() : null);
    if (encrypted == null) return {};
    final plain = _dpapi(encrypted, protect: false);
    if (plain == null) throw FileSystemException('Windows could not decrypt the secrets file', file.path);
    try {
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is Map) {
        return {
          for (final e in decoded.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
        };
      }
    } on FormatException {
      // Reported below; the file stays for the user to recover or remove.
    }
    throw FileSystemException('The secrets file is not valid', file.path);
  }

  Future<void> _save(Map<String, String> secrets) async {
    final path = await _path;
    final encrypted = _dpapi(utf8.encode(jsonEncode(secrets)), protect: true);
    if (encrypted == null) throw FileSystemException('Windows could not encrypt the secrets', path);
    final tmp = File('$path.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes(encrypted, flush: true);
      await _retry(() => tmp.rename(path));
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Left for the OS temp cleanup; it holds only DPAPI ciphertext.
      }
    }
  }

  Future<T> _retry<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } on FileSystemException {
        if (attempt >= retries.length) rethrow;
        await Future<void>.delayed(retries[attempt]);
      }
    }
  }
}

const _uiForbidden = 1;

/// Plaintext copies in native memory are wiped before they are released.
Uint8List? _dpapi(List<int> input, {required bool protect}) {
  final source = calloc<_Blob>(), result = calloc<_Blob>();
  final buffer = calloc<Uint8>(input.isEmpty ? 1 : input.length);
  try {
    buffer.asTypedList(input.length).setAll(0, input);
    source.ref
      ..size = input.length
      ..data = buffer;
    final ok = (protect ? _protect : _unprotect)(source, nullptr, nullptr, nullptr, nullptr, _uiForbidden, result);
    if (ok == 0 || result.ref.data == nullptr) return null;
    final output = result.ref.data.asTypedList(result.ref.size);
    final copy = Uint8List.fromList(output);
    if (!protect) output.fillRange(0, output.length, 0);
    return copy;
  } finally {
    if (result.ref.data != nullptr) _localFree(result.ref.data.cast());
    buffer.asTypedList(input.length).fillRange(0, input.length, 0);
    calloc
      ..free(buffer)
      ..free(source)
      ..free(result);
  }
}

final class _Blob extends Struct {
  @Uint32()
  external int size;
  external Pointer<Uint8> data;
}

// CryptProtectData and CryptUnprotectData differ only in the description argument, which is always null here.
typedef _CryptNative = Int32 Function(
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _CryptDart = int Function(
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);

final _crypt32 = DynamicLibrary.open('crypt32.dll');
final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
final _unprotect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
final _localFree = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
