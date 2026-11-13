import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/capabilities/files.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/result.dart';

class _Fs implements FileSystem, BoundedFileListing {
  final files = <String, Uint8List>{};
  final modes = <String, int>{};
  final folders = <String, List<FileEntry>>{'/': []};
  final aliases = <String, String>{};
  final deleted = <String>[];
  final published = <String>[];
  final contentModes = <int>[];
  final calls = <String>[];
  void Function()? afterAppend, afterDelete, afterList, afterReadChunk;
  var reads = 0, scans = 0;
  int? scanLimit;
  @override
  bool canReplace = true;
  @override
  bool canChmod = true;

  @override
  PathStyle get style => PathStyle.posix;

  @override
  Future<String> resolve(String path) async {
    calls.add('resolve:$path');
    for (final alias in aliases.entries) {
      if (path == alias.key || path.startsWith('${alias.key}/')) {
        return '${alias.value}${path.substring(alias.key.length)}';
      }
    }
    return path;
  }

  @override
  Future<FileEntry?> stat(String path) async {
    calls.add('stat:$path');
    final data = files[path];
    if (data != null) return FileEntry(style.name(path), FileKind.file, size: data.length, mode: modes[path] ?? 0x1A4);
    if (folders.containsKey(path)) return FileEntry(style.name(path), FileKind.directory, mode: 0x1C0);
    return null;
  }

  @override
  Stream<Uint8List> read(String path, {int offset = 0}) async* {
    reads++;
    final data = files[path];
    if (data == null) throw const FsError(FsFailure.notFound);
    for (var start = offset; start < data.length; start += 7) {
      yield Uint8List.sublistView(data, start, min(start + 7, data.length));
      afterReadChunk?.call();
    }
  }

  @override
  Future<int> create(
    String path,
    Stream<Uint8List> data, {
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) async {
    if (files.containsKey(path)) throw const FsError(FsFailure.exists);
    final builder = BytesBuilder();
    await for (final chunk in data) {
      builder.add(chunk);
    }
    files[path] = builder.takeBytes();
    modes[path] = 0x1A4;
    return files[path]!.length;
  }

  @override
  Future<int> append(
    String path,
    Stream<Uint8List> data, {
    required int offset,
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) async {
    contentModes.add(modes[path]!);
    final builder = BytesBuilder()..add(files[path]!);
    await for (final chunk in data) {
      builder.add(chunk);
    }
    files[path] = builder.takeBytes();
    afterAppend?.call();
    return files[path]!.length - offset;
  }

  @override
  Future<void> chmod(String path, int mode) async => modes[path] = mode;

  @override
  Future<void> rename(String from, String to, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    if (!files.containsKey(from)) throw const FsError(FsFailure.notFound);
    if (files.containsKey(to)) throw const FsError(FsFailure.exists);
    published.add(to);
    files[to] = files.remove(from)!;
    modes[to] = modes.remove(from)!;
  }

  @override
  Future<void> replace(String from, String to, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    if (!canReplace) throw const FsError(FsFailure.unsupported, 'atomicReplace');
    if (!files.containsKey(to)) throw const FsError(FsFailure.notFound);
    published.add(to);
    files[to] = files.remove(from)!;
    modes[to] = modes.remove(from)!;
  }

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
    files.remove(path);
    modes.remove(path);
    afterDelete?.call();
  }

  @override
  Future<void> rmdir(String path) async {
    deleted.add(path);
    folders.remove(path);
  }

  @override
  Future<List<FileEntry>> list(String dir) async {
    final entries = folders[dir] ?? const [];
    afterList?.call();
    return entries;
  }

  @override
  Future<BoundedListing> listBounded(
    String dir, {
    required int maxScanned,
    bool Function(String name)? accept,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) async {
    scans++;
    scanLimit = maxScanned;
    final all = folders[dir] ?? const [];
    final entries = all.take(maxScanned).where((entry) => accept?.call(entry.name) ?? true).toList();
    afterList?.call();
    return BoundedListing(entries, scanned: min(all.length, maxScanned), complete: all.length <= maxScanned);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected ${invocation.memberName}');
}

Args _args(Map<String, Object?> values) => Args(values);
Matcher _fsFailure(FsFailure kind) => throwsA(isA<FsError>().having((e) => e.kind, 'kind', kind));
Matcher _opFailure(String code) => throwsA(isA<OpFailure>().having((e) => e.code, 'code', code));
Uint8List _text(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  test('Agent transfer listing excludes local paths, host addresses and adapter details', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-transfer-projection-');
    await File('${dir.path}/transfers.json').writeAsString(
      jsonEncode({
        'transfers': [
          {
            'id': 'safe-transfer',
            'batch': 'batch',
            'source': {'path': r'C:\Users\fixture\.ssh\private', 'label': 'private-local-label'},
            'target': {'host': 'remote-id', 'path': '/home/fixture/.env', 'label': 'user@private.invalid'},
            'created': DateTime.now().toUtc().toIso8601String(),
            'state': 'failed',
            'bytes': 7,
            'total': 9,
            'files': 0,
            'error': 'permission',
            'detail': 'adapter-private-detail',
          },
        ],
      }),
    );
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });
    final capabilities = container.read(Provider((ref) => fileCapabilities(ref)));
    final listing = capabilities.singleWhere((capability) => capability.id == 'transfer.list');
    final result = await listing.invoke({}, RequestContext(Origin.agent)) as Ok<Object?>;
    expect(result.value, [
      {'id': 'safe-transfer', 'state': 'failed', 'bytes': 7, 'total': 9, 'files': 0, 'error': 'permission'},
    ]);
    expect(jsonEncode(result.value), isNot(contains('private')));
    expect(jsonEncode(result.value), isNot(contains('/home/fixture')));
  });

  test('reads UTF-8 pages without splitting a character and returns the whole-file digest', () async {
    final fs = _Fs();
    fs.files['/data.txt'] = _text('${'a' * 12287}你tail');
    final first = await readTextFile(fs, _args({'path': '/data.txt'})) as Map;
    expect(first['eof'], isFalse);
    expect(first['offset'], 0);
    expect(first['nextOffset'], 12287);
    expect(first['text'], 'a' * 12287);
    expect(first['sha256'], fileTextSha256(fs.files['/data.txt']!));
    final second = await readTextFile(fs, _args({'path': '/data.txt', 'offset': first['nextOffset']!})) as Map;
    expect(second['eof'], isTrue);
    expect(second['nextOffset'], isNull);
    expect(second['text'], '你tail');
    expect(second['sha256'], first['sha256']);
    await expectLater(readTextFile(fs, _args({'path': '/data.txt', 'offset': 12288})), _opFailure('invalidArgument'));
  });

  test('refuses binary, malformed UTF-8 and oversized files', () async {
    final fs = _Fs();
    for (final bytes in [
      Uint8List.fromList([1, 0, 2]),
      Uint8List.fromList([0xFF, 0xFE]),
      Uint8List.fromList([27, 91, 65]),
      Uint8List(262145),
    ]) {
      fs.files['/data.txt'] = bytes;
      await expectLater(readTextFile(fs, _args({'path': '/data.txt'})), _fsFailure(FsFailure.unsupported));
    }
  });

  test('rejects known secret locations before read, including canonical ancestor links', () async {
    final fs = _Fs();
    for (final path in [
      '/home/u/.ssh/id_ed25519',
      '/home/u/.env.prod',
      '/etc/shadow',
      '/proc/self/environ',
      '/a.pem',
      '/home/u/.bash_history',
      '/backup/id_ed25519',
      '/home/u/.config/rclone/rclone.conf',
    ]) {
      fs.files[path] = _text('private fixture');
      await expectLater(readTextFile(fs, _args({'path': path})), _opFailure('denied'));
    }
    fs.files['/public/key'] = _text('fixture');
    fs.aliases['/public'] = '/home/u/.ssh';
    await expectLater(readTextFile(fs, _args({'path': '/public/key'})), _opFailure('denied'));
    fs.aliases['/public'] = '/home/u/.aws';
    await expectLater(writeTextFile(fs, _args({'path': '/public/new.txt', 'text': 'fixture'})), _opFailure('denied'));
    expect(fs.reads, 0);
    expect(fs.published, isEmpty);
  });

  test('rejects secret content after the first page before returning any text', () async {
    final fs = _Fs();
    fs.files['/config.txt'] = _text('${'x' * 13000}\napi_key=synthetic-fixture');
    await expectLater(readTextFile(fs, _args({'path': '/config.txt'})), _opFailure('denied'));
  });

  test('creates with private content and replaces only with a matching baseline while preserving mode', () async {
    final fs = _Fs();
    final created = await writeTextFile(fs, _args({'path': '/new.txt', 'text': 'hello'})) as Map;
    expect(created['created'], isTrue);
    expect(utf8.decode(fs.files['/new.txt']!), 'hello');
    expect(fs.modes['/new.txt'], 0x180);
    expect(fs.contentModes, [0x180]);
    await expectLater(writeTextFile(fs, _args({'path': '/new.txt', 'text': 'again'})), _fsFailure(FsFailure.exists));
    await expectLater(
      writeTextFile(fs, _args({'path': '/new.txt', 'text': 'again', 'overwrite': true})),
      _opFailure('invalidArgument'),
    );
    fs.modes['/new.txt'] = 0x1ED;
    final replaced = await writeTextFile(
      fs,
      _args({'path': '/new.txt', 'text': 'again', 'overwrite': true, 'expectedSha256': created['sha256']}),
    ) as Map;
    expect(replaced['created'], isFalse);
    expect(utf8.decode(fs.files['/new.txt']!), 'again');
    expect(fs.modes['/new.txt'], 0x1ED);
    expect(fs.contentModes, everyElement(0x180));
    expect(fs.files.keys.where((path) => path.contains('.sshairy-tmp-')), isEmpty);
  });

  test('detects equal-length edits during staging and leaves the changed target intact', () async {
    final fs = _Fs();
    fs.files['/kept.txt'] = _text('old');
    final baseline = fileTextSha256(fs.files['/kept.txt']!);
    fs.afterAppend = () => fs.files['/kept.txt'] = _text('new');
    await expectLater(
      writeTextFile(
        fs,
        _args({'path': '/kept.txt', 'text': 'replacement', 'overwrite': true, 'expectedSha256': baseline}),
      ),
      _opFailure('conflict'),
    );
    expect(utf8.decode(fs.files['/kept.txt']!), 'new');
    expect(fs.published, isEmpty);
    expect(fs.files.keys, ['/kept.txt']);
  });

  test('does not stage when the baseline already changed or atomic replacement is unavailable', () async {
    final fs = _Fs();
    fs.files['/kept.txt'] = _text('old');
    await expectLater(
      writeTextFile(
        fs,
        _args({'path': '/kept.txt', 'text': 'new', 'overwrite': true, 'expectedSha256': fileTextSha256(_text('bad'))}),
      ),
      _opFailure('conflict'),
    );
    fs.canReplace = false;
    await expectLater(
      writeTextFile(
        fs,
        _args({'path': '/kept.txt', 'text': 'new', 'overwrite': true, 'expectedSha256': fileTextSha256(_text('old'))}),
      ),
      _fsFailure(FsFailure.unsupported),
    );
    expect(utf8.decode(fs.files['/kept.txt']!), 'old');
    expect(fs.contentModes, isEmpty);
    expect(fs.files.keys, ['/kept.txt']);
  });

  test('Stop after staged content is written prevents publication and cleans owned staging', () async {
    final fs = _Fs();
    final cancel = CancellationToken();
    fs.afterAppend = cancel.cancel;
    await expectLater(
      writeTextFile(
        fs,
        _args({'path': '/new.txt', 'text': 'fixture'}),
        context: RequestContext(Origin.agent, cancellation: cancel),
      ),
      _opFailure('cancelled'),
    );
    expect(fs.published, isEmpty);
    expect(fs.files, isEmpty);
  });

  test('Stop during a read stops before another chunk can be returned', () async {
    final fs = _Fs();
    fs.files['/data.txt'] = _text('x' * 100);
    final cancel = CancellationToken();
    fs.afterReadChunk = cancel.cancel;
    await expectLater(
      readTextFile(fs, _args({'path': '/data.txt'}), context: RequestContext(Origin.agent, cancellation: cancel)),
      _opFailure('cancelled'),
    );
  });

  test('bounded directory scan reports incomplete and output paging honestly', () async {
    final fs = _Fs();
    fs.folders['/'] = [for (var i = 0; i < 10001; i++) FileEntry('file-$i', FileKind.file)];
    final page = await listFiles(fs, _args({'path': '/', 'offset': 200}), RequestContext(Origin.agent)) as Map;
    expect(fs.scanLimit, 10000);
    expect(page['entries'], hasLength(200));
    expect(page['nextOffset'], 400);
    expect(page['total'], isNull);
    expect(page['complete'], isFalse);
    expect(page['scanned'], 10000);
    fs.folders['/'] = [const FileEntry('only', FileKind.file)];
    final complete = await listFiles(fs, _args({'path': '/'}), RequestContext(Origin.agent)) as Map;
    expect(complete['complete'], isTrue);
    expect(complete['nextOffset'], isNull);
    expect(complete['total'], 1);
  });

  test('recursive deletion checks Stop after each deletion and before the directory', () async {
    final fs = _Fs();
    fs.folders['/owned'] = [const FileEntry('one', FileKind.file), const FileEntry('two', FileKind.file)];
    fs.files['/owned/one'] = _text('1');
    fs.files['/owned/two'] = _text('2');
    final cancel = CancellationToken();
    fs.afterDelete = cancel.cancel;
    await expectLater(
      deleteTree(fs, '/owned', const FileEntry('owned', FileKind.directory), cancel: cancel),
      _opFailure('cancelled'),
    );
    expect(fs.deleted, ['/owned/one']);
    expect(fs.files.containsKey('/owned/two'), isTrue);
    expect(fs.folders.containsKey('/owned'), isTrue);
  });

  test('recursive deletion removes symlinks without entering their targets', () async {
    final fs = _Fs();
    fs.folders['/owned'] = [const FileEntry('link', FileKind.link, linkToDir: true)];
    fs.folders['/owned/link'] = [const FileEntry('keep', FileKind.file)];
    fs.files['/owned/link/keep'] = _text('fixture');
    await deleteTree(fs, '/owned', const FileEntry('owned', FileKind.directory));
    expect(fs.deleted, ['/owned/link', '/owned']);
    expect(fs.files.containsKey('/owned/link/keep'), isTrue);
  });

  test('recursive deletion refuses a directory beyond its scan budget before deleting children', () async {
    final fs = _Fs();
    fs.folders['/owned'] = [for (var i = 0; i < 20000; i++) FileEntry('file-$i', FileKind.file)];
    await expectLater(
      deleteTree(fs, '/owned', const FileEntry('owned', FileKind.directory)),
      _opFailure('treeTooLarge'),
    );
    expect(fs.scanLimit, 19999);
    expect(fs.deleted, isEmpty);
  });

  test('recursive deletion checks Stop after listing an empty directory and checks its deadline', () async {
    final fs = _Fs();
    fs.folders['/owned'] = [];
    final cancel = CancellationToken();
    fs.afterList = cancel.cancel;
    await expectLater(
      deleteTree(fs, '/owned', const FileEntry('owned', FileKind.directory), cancel: cancel),
      _opFailure('cancelled'),
    );
    await expectLater(
      deleteTree(
        fs,
        '/owned',
        const FileEntry('owned', FileKind.directory),
        deadline: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
      _opFailure('deadlineExceeded'),
    );
    expect(fs.deleted, isEmpty);
  });
}
