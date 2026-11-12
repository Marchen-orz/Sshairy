import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/capabilities/files.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/file_system.dart';

class _Fs implements FileSystem {
  final files = <String, Uint8List>{};
  @override
  bool canReplace = true;

  @override
  PathStyle get style => PathStyle.posix;

  @override
  Future<FileEntry?> stat(String path) async {
    final data = files[path];
    return data == null ? null : FileEntry(style.name(path), FileKind.file, size: data.length);
  }

  @override
  Stream<Uint8List> read(String path, {int offset = 0}) async* {
    final data = files[path];
    if (data == null) throw const FsError(FsFailure.notFound);
    for (var start = offset; start < data.length; start += 7) {
      yield Uint8List.sublistView(data, start, min(start + 7, data.length));
    }
  }

  @override
  Future<int> create(
    String path,
    Stream<Uint8List> data, {
    void Function(int written)? onProgress,
    CancellationToken? cancel,
  }) async {
    if (files.containsKey(path)) throw const FsError(FsFailure.exists);
    final builder = BytesBuilder();
    await for (final chunk in data) {
      builder.add(chunk);
    }
    files[path] = builder.takeBytes();
    return files[path]!.length;
  }

  @override
  Future<void> rename(String from, String to) async {
    if (!files.containsKey(from)) throw const FsError(FsFailure.notFound);
    if (files.containsKey(to)) throw const FsError(FsFailure.exists);
    files[to] = files.remove(from)!;
  }

  @override
  Future<void> replace(String from, String to) async {
    if (!canReplace) throw const FsError(FsFailure.unsupported, 'atomicReplace');
    if (!files.containsKey(to)) throw const FsError(FsFailure.notFound);
    files[to] = files.remove(from)!;
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected ${invocation.memberName}');
}

Args _args(Map<String, Object?> values) => Args(values);

void main() {
  test('reads a UTF-8 file in bounded pages and never splits a character', () async {
    final fs = _Fs();
    final head = utf8.encode('a' * 12287);
    fs.files['/data.txt'] = Uint8List.fromList([...head, ...utf8.encode('你'), ...utf8.encode('tail')]);

    final first = await readTextFile(fs, _args({'path': '/data.txt'})) as Map;
    expect(first['eof'], isFalse);
    expect(first['offset'], 0);
    expect(first['nextOffset'], 12287);
    expect(first['text'], 'a' * 12287);

    final second = await readTextFile(fs, _args({'path': '/data.txt', 'offset': first['nextOffset']!})) as Map;
    expect(second['eof'], isTrue);
    expect(second['nextOffset'], isNull);
    expect(second['text'], '你tail');
  });

  test('refuses binary and oversized files instead of returning mangled text', () async {
    final fs = _Fs();
    fs.files['/binary.bin'] = Uint8List.fromList([1, 0, 2]);
    await expectLater(
      readTextFile(fs, _args({'path': '/binary.bin'})),
      throwsA(isA<FsError>().having((e) => e.kind, 'kind', FsFailure.unsupported)),
    );

    fs.files['/large.txt'] = Uint8List(256 * 1024 + 1);
    await expectLater(
      readTextFile(fs, _args({'path': '/large.txt'})),
      throwsA(isA<FsError>().having((e) => e.kind, 'kind', FsFailure.unsupported)),
    );
  });

  test('creates without replacing and atomically replaces only when asked', () async {
    final fs = _Fs();
    final created = await writeTextFile(fs, _args({'path': '/new.txt', 'text': 'hello'})) as Map;
    expect(created['created'], isTrue);
    expect(utf8.decode(fs.files['/new.txt']!), 'hello');

    await expectLater(
      writeTextFile(fs, _args({'path': '/new.txt', 'text': 'again'})),
      throwsA(isA<FsError>().having((e) => e.kind, 'kind', FsFailure.exists)),
    );
    expect(utf8.decode(fs.files['/new.txt']!), 'hello');

    final replaced = await writeTextFile(fs, _args({'path': '/new.txt', 'text': 'again', 'overwrite': true})) as Map;
    expect(replaced['created'], isFalse);
    expect(utf8.decode(fs.files['/new.txt']!), 'again');
    expect(fs.files.keys.where((path) => path.contains('.sshairy-tmp-')), isEmpty);
  });

  test('does not touch the target when atomic replacement is unsupported', () async {
    final fs = _Fs()..canReplace = false;
    fs.files['/kept.txt'] = Uint8List.fromList(utf8.encode('old'));
    await expectLater(
      writeTextFile(fs, _args({'path': '/kept.txt', 'text': 'new', 'overwrite': true})),
      throwsA(isA<FsError>().having((e) => e.kind, 'kind', FsFailure.unsupported)),
    );
    expect(utf8.decode(fs.files['/kept.txt']!), 'old');
    expect(fs.files.keys.where((path) => path.contains('.sshairy-tmp-')), isEmpty);
  });
}
