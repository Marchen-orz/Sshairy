import 'dart:async';

import 'package:dartssh2/dartssh2.dart' show SftpFileAttrs, SftpFileMode, SftpName;
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/adapters/sftp_fs.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/adapters/terminal_paths.dart';
import 'package:sshairy/features/terminal/domain/terminal_paths.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

Matcher failsWith(RemotePathFailure kind) => throwsA(isA<RemotePathException>().having((e) => e.kind, 'kind', kind));

RemoteDirectoryItem dir(String name) => RemoteDirectoryItem(name, RemotePathKind.directory);
RemoteDirectoryItem file(String name) => RemoteDirectoryItem(name, RemotePathKind.file);
RemoteDirectoryItem link(String name, {bool toDir = false}) =>
    RemoteDirectoryItem(name, RemotePathKind.symlink, linkToDirectory: toDir);

List<String> names(RemotePathResult result) => [for (final e in result.entries) e.name];

Future<void> pause([int milliseconds = 10]) => Future<void>.delayed(Duration(milliseconds: milliseconds));

/// Answers from a map and never touches a file system; a gate holds a listing until opened or aborted.
class _Reader implements RemoteDirectoryReader {
  _Reader(this.tree, {this.homePath = '/home/u'});

  final Map<String, List<RemoteDirectoryItem>> tree;
  String homePath;
  final listed = <String>[];
  final gates = <String, Completer<void>>{};

  /// Directories whose listing stops short, as one cut off at the scan limit does.
  final incomplete = <String>{};
  var homes = 0, aborted = 0;
  var closed = false;
  RemotePathFailure? failNext;

  @override
  Future<String> home(CancellationToken cancel) async {
    homes++;
    return homePath;
  }

  @override
  Future<RemoteDirectoryListing> list(String directory, CancellationToken cancel) async {
    listed.add(directory);
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw RemotePathException(failure);
    }
    final gate = gates[directory];
    if (gate != null) {
      await Future.any<void>([
        gate.future,
        cancel.whenCancelled.then<void>((_) {
          aborted++;
          throw const RemotePathException(RemotePathFailure.cancelled);
        }),
      ]);
    }
    final items = tree[directory];
    if (items == null) throw const RemotePathException(RemotePathFailure.notFound);
    return RemoteDirectoryListing(items, complete: !incomplete.contains(directory));
  }

  @override
  void close() => closed = true;
}

class _Files implements FileSystem {
  _Files({this.entries = const [], this.gate, this.error});

  final List<FileEntry> entries;
  final Completer<void>? gate;
  final Object? error;
  final listed = <String>[];
  var closes = 0;

  @override
  PathStyle get style => PathStyle.posix;

  @override
  Future<String> home() async => '/home/u';

  @override
  Future<List<FileEntry>> list(String dir) async {
    listed.add(dir);
    final failure = error;
    if (failure != null) throw failure;
    await gate?.future;
    return entries;
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// A file system that also scans: it hands back what [entries] holds after [accept], and says whether that is all.
class _Bounded extends _Files implements BoundedFileListing {
  _Bounded({super.entries, super.gate, super.error, this.complete = true});

  final bool complete;
  final scans = <(String, int)>[];
  bool Function(String name)? accepted;
  CancellationToken? scanCancel;

  @override
  Future<BoundedListing> listBounded(
    String dir, {
    required int maxScanned,
    bool Function(String name)? accept,
    CancellationToken? cancel,
  }) async {
    scans.add((dir, maxScanned));
    accepted = accept;
    scanCancel = cancel;
    final failure = error;
    if (failure != null) throw failure;
    await gate?.future;
    return BoundedListing(
      [
        for (final e in entries)
          if (accept?.call(e.name) ?? true) e,
      ],
      scanned: entries.length,
      complete: complete,
    );
  }
}

const _dirMode = 0x41ed, _fileMode = 0x81a4, _linkMode = 0xa1ff;

SftpName sftpName(String name, [int mode = _fileMode]) => SftpName(
  filename: name,
  longname: '',
  attr: SftpFileAttrs(mode: SftpFileMode.value(mode)),
);

/// READDIR batches handed out on demand; [drained] stays false when the reader stops before the last one.
class _Readdir {
  _Readdir(this.batches, {this.onPull});

  final List<List<SftpName>> batches;
  final void Function(int pulled)? onPull;
  var pulled = 0;
  var drained = false;

  Stream<List<SftpName>> get stream async* {
    for (final batch in batches) {
      pulled++;
      onPull?.call(pulled);
      yield batch;
    }
    drained = true;
  }
}

class _Server extends FakeTransport {
  _Server(this.files);

  final _Files files;
  var opened = 0;

  @override
  Future<FileSystem> openFiles() async {
    opened++;
    return files;
  }
}

void main() {
  group('paths', () {
    test('normalize drops empty and dot segments, keeps dot-dot and unusual names', () {
      expect(RemotePaths.normalize('/'), '/');
      expect(RemotePaths.normalize('/a//b/./c/'), '/a/b/c');
      expect(RemotePaths.normalize('/a/../b'), '/a/../b');
      expect(RemotePaths.normalize('~'), '~');
      expect(RemotePaths.normalize('~/'), '~');
      expect(RemotePaths.normalize('~//x/./y/'), '~/x/y');
      expect(RemotePaths.normalize('/x/~'), '/x/~');
      expect(RemotePaths.normalize('/srv/my dir/日本語/😀'), '/srv/my dir/日本語/😀');
      expect(RemotePaths.normalize("/it's/a \"quote\"/\$HOME/a\\b"), "/it's/a \"quote\"/\$HOME/a\\b");
    });

    test('normalize rejects relative paths, other users homes and unusable text', () {
      final bad = <String>[
        '',
        'a/b',
        './a',
        '~root',
        '~root/x',
        '~+',
        '~-/x',
        '/a\nb',
        '/a\rb',
        '/a\u0000b',
        '/a\tb',
        '/a\u001bb',
        '/a\u007fb',
        '/a\u0085b',
        '/a\u2028b',
        '/a\u202eb',
        '/a\ufffdb',
        '/a${String.fromCharCode(0xd800)}b',
        '/a${String.fromCharCode(0xdc00)}b',
        '/${'a' * 4096}',
        '/${'a' * 256}',
        '/${List.filled(129, 'a').join('/')}',
        '/${List.filled(20, '日' * 85).join('/')}',
      ];
      for (final path in bad) {
        expect(() => RemotePaths.normalize(path), failsWith(RemotePathFailure.invalid), reason: path);
      }
      expect(RemotePaths.normalize('/${List.filled(128, 'a').join('/')}'), isNotEmpty);
      expect(RemotePaths.normalize('/${'日' * 85}'), isNotEmpty);
    });

    test('names must survive as one path segment', () {
      for (final good in ['a b', '日本語', '😀', '.hidden', 'a\\b', "it's", 'x' * 255, '日' * 85, '-rf']) {
        expect(RemotePaths.validName(good), isTrue, reason: good);
      }
      final bad = <String>[
        '',
        '.',
        '..',
        'a/b',
        'a\nb',
        'a\rb',
        'a\tb',
        'a\u0000b',
        'a\u007fb',
        'a\u0085b',
        'a\u2028b',
        'a\u2029b',
        'a\u202eb',
        'a\u2067b',
        'a\ufffdb',
        String.fromCharCode(0xd83d),
        'x' * 256,
        '日' * 86,
      ];
      for (final name in bad) {
        expect(RemotePaths.validName(name), isFalse, reason: name);
      }
    });

    test('prefixes are one typed segment', () {
      for (final good in ['', 'a', '.', '..x', '日本', 'my fi']) {
        expect(RemotePaths.validPrefix(good), isTrue, reason: good);
      }
      for (final bad in ['a/b', '/', 'a\nb', 'a\u202eb', 'x' * 256]) {
        expect(RemotePaths.validPrefix(bad), isFalse, reason: bad);
      }
    });

    test('child and parent move one level and never leave the root', () {
      expect(RemotePaths.child('/', 'a'), '/a');
      expect(RemotePaths.child('/a/', 'b c'), '/a/b c');
      expect(RemotePaths.child('~', 'x'), '~/x');
      for (final name in ['', '..', 'a/b', 'a\nb']) {
        expect(() => RemotePaths.child('/a', name), throwsArgumentError, reason: name);
      }
      expect(RemotePaths.parent('/a/b'), '/a');
      expect(RemotePaths.parent('/a'), '/');
      expect(RemotePaths.parent('/'), '/');
      expect(RemotePaths.parent('~/a'), '~');
      expect(RemotePaths.parent('~'), '~/..');
      expect(RemotePaths.parent('/a/..'), '/a/../..');
    });

    test('home expands from an absolute home only', () {
      expect(RemotePaths.expandHome('~', '/home/u'), '/home/u');
      expect(RemotePaths.expandHome('~/src', '/home/u/'), '/home/u/src');
      expect(RemotePaths.expandHome('~/src', '/'), '/src');
      expect(RemotePaths.expandHome('/etc', '/home/u'), '/etc');
      expect(() => RemotePaths.expandHome('~', 'home'), failsWith(RemotePathFailure.invalid));
      expect(() => RemotePaths.expandHome('~', '~'), failsWith(RemotePathFailure.invalid));
    });

    test('relative input is taken from a trusted cwd or not at all', () {
      expect(RemotePaths.absolute('/a/b/'), '/a/b');
      expect(RemotePaths.absolute('~/x'), '~/x');
      expect(RemotePaths.absolute('src/', cwd: '/home/u'), '/home/u/src');
      expect(RemotePaths.absolute('', cwd: '/x'), '/x');
      expect(RemotePaths.absolute('../y', cwd: '/x/z'), '/x/z/../y');
      expect(RemotePaths.absolute('src'), isNull);
      expect(RemotePaths.absolute('', cwd: null), isNull);
      expect(RemotePaths.absolute('~root/x', cwd: '/x'), isNull);
      expect(RemotePaths.absolute('a', cwd: '~'), isNull);
      expect(RemotePaths.absolute('a', cwd: 'relative'), isNull);
      expect(RemotePaths.absolute('a\nb', cwd: '/x'), isNull);
    });
  });

  group('browser', () {
    RemotePathBrowser make(_Reader reader, {Duration timeout = const Duration(seconds: 3)}) {
      final browser = RemotePathBrowser(reader, generation: 7, timeout: timeout);
      addTearDown(browser.dispose);
      return browser;
    }

    test('lists directories first, matches the prefix case-sensitively and hides dotfiles', () async {
      final reader = _Reader({
        '/srv': [
          file('b.txt'),
          dir('Apple'),
          dir('apple'),
          file('app.log'),
          file('.env'),
          dir('.git'),
          dir('zeta'),
          link('lnk', toDir: true),
          link('flink'),
        ],
      });
      final browser = make(reader);
      final all = await browser.browse(const RemotePathQuery(directory: '/srv'));
      expect(names(all), ['Apple', 'apple', 'lnk', 'zeta', 'app.log', 'b.txt', 'flink']);
      expect(all.directory, '/srv');
      expect(all.generation, 7);
      expect(all.truncated, isFalse);
      expect(all.cached, isFalse);

      final lnk = all.entries.firstWhere((e) => e.name == 'lnk');
      expect(
        (lnk.kind, lnk.linkToDirectory, lnk.enterable, lnk.path),
        (RemotePathKind.symlink, true, true, '/srv/lnk'),
      );
      final flink = all.entries.firstWhere((e) => e.name == 'flink');
      expect((flink.kind, flink.linkToDirectory, flink.enterable), (RemotePathKind.symlink, false, false));

      Future<List<String>> ask(String prefix, {bool foldersOnly = false}) async =>
          names(await browser.browse(RemotePathQuery(directory: '/srv', prefix: prefix, foldersOnly: foldersOnly)));
      expect(await ask('app'), ['apple', 'app.log']);
      expect(await ask('A'), ['Apple']);
      expect(await ask('a'), ['apple', 'app.log']);
      expect(await ask('.'), ['.git', '.env']);
      expect(await ask('.g'), ['.git']);
      expect(await ask('nothing'), isEmpty);
      expect(await ask('', foldersOnly: true), ['Apple', 'apple', 'lnk', 'zeta']);
      expect(reader.listed, ['/srv'], reason: 'one listing serves every prefix');
    });

    test('keeps names with spaces and Unicode and drops the ones that cannot be offered', () async {
      final reader = _Reader({
        '/data': [
          file('my file.txt'),
          dir('日本語'),
          dir('😀 dir'),
          file('bad\nname'),
          file('esc\u001b[31m'),
          file('a\u202eb'),
          file('x' * 300),
          file('sl/ash'),
          file(''),
          file('.'),
          file('..'),
          file('dup'),
          file('dup'),
          file('tab\there'),
          file('nul\u0000x'),
          file('bad\ufffdname'),
        ],
      });
      final result = await make(reader).browse(const RemotePathQuery(directory: '/data'));
      expect(names(result), ['日本語', '😀 dir', 'dup', 'my file.txt']);
      expect(result.entries.last.path, '/data/my file.txt');
    });

    test('shows at most 200 entries and says when there were more', () async {
      final reader = _Reader({
        '/big': [
          for (var i = 0; i < 500; i++) file('f${i.toString().padLeft(3, '0')}'),
          for (var i = 0; i < 5; i++) dir('d$i'),
        ],
      });
      final browser = make(reader);
      final result = await browser.browse(const RemotePathQuery(directory: '/big'));
      expect(result.entries, hasLength(200));
      expect(result.truncated, isTrue);
      expect(names(result).take(7).toList(), ['d0', 'd1', 'd2', 'd3', 'd4', 'f000', 'f001']);
      final narrow = await browser.browse(const RemotePathQuery(directory: '/big', prefix: 'f4'));
      expect(narrow.entries, hasLength(100));
      expect(narrow.truncated, isFalse);
    });

    test('a listing that stopped at the scan limit is answered, kept, and reported as truncated', () async {
      final reader = _Reader({
        '/huge': [file('a'), file('b')],
      })..incomplete.add('/huge');
      final browser = make(reader);
      final first = await browser.browse(const RemotePathQuery(directory: '/huge', prefix: 'a'));
      expect(names(first), ['a']);
      expect(first.truncated, isTrue, reason: 'fewer than 200 matched, but not every name was read');
      final again = await browser.browse(const RemotePathQuery(directory: '/huge', prefix: 'b'));
      expect(names(again), ['b']);
      expect((again.cached, again.truncated), (true, true));
      expect(reader.listed, ['/huge']);
    });

    test('names a reader hands over beyond the scan limit are dropped', () async {
      String name(int i) => 'f${i.toString().padLeft(4, '0')}';
      final reader = _Reader({
        '/many': [for (var i = 0; i < RemotePaths.maxScanned + 904; i++) file(name(i))],
        '/exact': [for (var i = 0; i < RemotePaths.maxScanned; i++) file(name(i))],
      });
      final browser = make(reader);
      final over = await browser.browse(const RemotePathQuery(directory: '/many', prefix: 'f4'));
      expect(over.entries, hasLength(96), reason: 'f4000 to f4095; the rest lies past 4096 names');
      expect(names(over).last, 'f4095');
      expect(over.truncated, isTrue);
      final exact = await browser.browse(const RemotePathQuery(directory: '/exact', prefix: 'f4'));
      expect(exact.entries, hasLength(96));
      expect(exact.truncated, isFalse);
    });

    test('expands home once through the reader and shares the cache with the absolute path', () async {
      final reader = _Reader({
        '/home/u': [dir('src')],
        '/home/u/src': [file('a.txt')],
      });
      final browser = make(reader);
      final src = await browser.browse(const RemotePathQuery(directory: '~/src/'));
      expect(src.directory, '/home/u/src');
      expect(src.entries.single.path, '/home/u/src/a.txt');
      final home = await browser.browse(const RemotePathQuery(directory: '~'));
      expect(home.directory, '/home/u');
      expect(reader.homes, 1);
      final again = await browser.browse(const RemotePathQuery(directory: '/home/u/src'));
      expect(again.cached, isTrue);
      expect((await browser.browse(const RemotePathQuery(directory: '~/src'))).cached, isTrue);
      expect(reader.listed, ['/home/u/src', '/home/u']);
    });

    test('a home the server cannot state is unavailable', () async {
      final reader = _Reader({}, homePath: 'home/u');
      await expectLater(
        make(reader).browse(const RemotePathQuery(directory: '~')),
        failsWith(RemotePathFailure.unavailable),
      );
      expect(reader.listed, isEmpty);
    });

    test('navigates down and up with the helpers', () async {
      final reader = _Reader({
        '/srv': [dir('proj')],
        '/srv/proj': [file('main.c')],
      });
      final browser = make(reader);
      final top = await browser.browse(const RemotePathQuery(directory: '/srv'));
      final entry = top.entries.single;
      expect(entry.path, RemotePaths.child(top.directory, entry.name));
      final down = await browser.browse(RemotePathQuery(directory: entry.path));
      expect(names(down), ['main.c']);
      final up = await browser.browse(RemotePathQuery(directory: RemotePaths.parent(down.directory)));
      expect(up.directory, '/srv');
      expect(up.cached, isTrue);
    });

    test('rejects bad queries before reading anything', () async {
      final reader = _Reader({
        '/': [file('a')],
      });
      final browser = make(reader);
      final queries = [
        const RemotePathQuery(directory: 'relative'),
        const RemotePathQuery(directory: '~root'),
        const RemotePathQuery(directory: '/a\nb'),
        const RemotePathQuery(directory: '/', prefix: 'a/b'),
        const RemotePathQuery(directory: '/', prefix: 'a\nb'),
        RemotePathQuery(directory: '/${'a' * 5000}'),
      ];
      for (final query in queries) {
        await expectLater(browser.browse(query), failsWith(RemotePathFailure.invalid));
      }
      final cancelled = CancellationToken()..cancel();
      await expectLater(
        browser.browse(const RemotePathQuery(directory: '/'), cancel: cancelled),
        failsWith(RemotePathFailure.cancelled),
      );
      expect(reader.listed, isEmpty);
      expect(reader.homes, 0);
    });

    group('cache', () {
      test('answers within the TTL, lists again after it, and can be invalidated', () async {
        var now = DateTime(2026, 11, 8);
        final reader = _Reader({
          '/srv': [file('a')],
          '/home/u': [file('b')],
        });
        final browser = RemotePathBrowser(reader, generation: 1, clock: () => now);
        addTearDown(browser.dispose);
        const query = RemotePathQuery(directory: '/srv');
        expect((await browser.browse(query)).cached, isFalse);
        expect((await browser.browse(query)).cached, isTrue);
        now = now.add(const Duration(seconds: 4, milliseconds: 900));
        expect((await browser.browse(query)).cached, isTrue);
        now = now.add(const Duration(milliseconds: 200));
        expect((await browser.browse(query)).cached, isFalse);
        expect(reader.listed, ['/srv', '/srv']);

        browser.invalidate('/srv');
        expect((await browser.browse(query)).cached, isFalse);
        expect((await browser.browse(const RemotePathQuery(directory: '~'))).cached, isFalse);
        browser.invalidate('~');
        expect((await browser.browse(const RemotePathQuery(directory: '/home/u'))).cached, isFalse);
        browser.invalidate();
        expect((await browser.browse(query)).cached, isFalse);
        browser.invalidate('not absolute');
        expect(reader.listed, ['/srv', '/srv', '/srv', '/home/u', '/home/u', '/srv']);
      });

      test('keeps at most 16 directories, the least recently used going first', () async {
        final reader = _Reader({
          for (var i = 0; i < 20; i++) '/d$i': [file('a')],
        });
        final browser = make(reader);
        for (var i = 0; i < 20; i++) {
          await browser.browse(RemotePathQuery(directory: '/d$i'));
        }
        expect(reader.listed, hasLength(20));
        expect((await browser.browse(const RemotePathQuery(directory: '/d19'))).cached, isTrue);
        expect((await browser.browse(const RemotePathQuery(directory: '/d4'))).cached, isTrue);
        expect((await browser.browse(const RemotePathQuery(directory: '/d0'))).cached, isFalse);
      });

      test('bounds the entries held in all and per directory, and still answers big directories', () async {
        final reader = _Reader({
          '/a': [for (var i = 0; i < 6; i++) file('a$i')],
          '/b': [for (var i = 0; i < 6; i++) file('b$i')],
          '/huge': [for (var i = 0; i < 5; i++) file('h$i')],
        });
        final browser = RemotePathBrowser(reader, generation: 1, maxCachedEntries: 10, maxEntriesPerDirectory: 5);
        addTearDown(browser.dispose);
        await browser.browse(const RemotePathQuery(directory: '/a'));
        expect((await browser.browse(const RemotePathQuery(directory: '/a'))).cached, isFalse, reason: '6 > 5 per dir');
        reader.tree['/a'] = [file('a0'), file('a1'), file('a2')];
        reader.tree['/b'] = [file('b0'), file('b1'), file('b2'), file('b3'), file('b4')];
        browser.invalidate();
        await browser.browse(const RemotePathQuery(directory: '/a'));
        await browser.browse(const RemotePathQuery(directory: '/b'));
        expect((await browser.browse(const RemotePathQuery(directory: '/b'))).cached, isTrue);
        await browser.browse(const RemotePathQuery(directory: '/huge'));
        expect(
          (await browser.browse(const RemotePathQuery(directory: '/a'))).cached,
          isFalse,
          reason: '3 + 5 + 5 > 10',
        );
      });

      test('remembers missing and slow directories for the TTL, not lost connections', () async {
        var now = DateTime(2026, 11, 8);
        final reader = _Reader({
          '/ok': [file('a')],
        });
        final browser = RemotePathBrowser(reader, generation: 1, clock: () => now);
        addTearDown(browser.dispose);
        const missing = RemotePathQuery(directory: '/nope');
        await expectLater(browser.browse(missing), failsWith(RemotePathFailure.notFound));
        await expectLater(browser.browse(missing), failsWith(RemotePathFailure.notFound));
        expect(reader.listed, ['/nope']);
        now = now.add(const Duration(seconds: 6));
        await expectLater(browser.browse(missing), failsWith(RemotePathFailure.notFound));
        expect(reader.listed, ['/nope', '/nope']);

        reader.failNext = RemotePathFailure.unavailable;
        await expectLater(
          browser.browse(const RemotePathQuery(directory: '/ok')),
          failsWith(RemotePathFailure.unavailable),
        );
        expect((await browser.browse(const RemotePathQuery(directory: '/ok'))).cached, isFalse);

        reader.failNext = RemotePathFailure.denied;
        await expectLater(
          browser.browse(const RemotePathQuery(directory: '/root')),
          failsWith(RemotePathFailure.denied),
        );
        await expectLater(
          browser.browse(const RemotePathQuery(directory: '/root')),
          failsWith(RemotePathFailure.denied),
        );
        expect(reader.listed.where((d) => d == '/root'), hasLength(1));
      });
    });

    group('flights', () {
      const srv = RemotePathQuery(directory: '/srv');

      test('queries for one directory share a single listing', () async {
        final reader = _Reader({
          '/srv': [file('a'), file('b')],
        })..gates['/srv'] = Completer<void>();
        final browser = make(reader);
        final one = browser.browse(const RemotePathQuery(directory: '/srv', prefix: 'a'));
        final two = browser.browse(const RemotePathQuery(directory: '/srv/', prefix: 'b'));
        await pause();
        reader.gates['/srv']!.complete();
        expect(names(await one), ['a']);
        expect(names(await two), ['b']);
        expect(reader.listed, ['/srv']);
      });

      test('a waiter that cancels leaves, the last one out stops the listing', () async {
        final reader = _Reader({
          '/srv': [file('x')],
          '/slow': [file('y')],
        })..gates['/srv'] = Completer<void>();
        reader.gates['/slow'] = Completer<void>();
        final browser = make(reader);
        final first = CancellationToken(), second = CancellationToken();
        final a = browser.browse(srv, cancel: first);
        final b = browser.browse(srv, cancel: second);
        final aFailure = expectLater(a, failsWith(RemotePathFailure.cancelled));
        await pause();
        first.cancel();
        await aFailure;
        await pause();
        expect(reader.aborted, 0, reason: 'b still waits');
        reader.gates['/srv']!.complete();
        expect(names(await b), ['x']);

        final only = CancellationToken();
        final c = browser.browse(const RemotePathQuery(directory: '/slow'), cancel: only);
        final cFailure = expectLater(c, failsWith(RemotePathFailure.cancelled));
        await pause();
        only.cancel();
        await cFailure;
        await pause();
        expect(reader.aborted, 1);
      });

      test('a query for another directory supersedes the running one', () async {
        final reader = _Reader({
          '/a': [file('x')],
          '/b': [file('y')],
        })..gates['/a'] = Completer<void>();
        final browser = make(reader);
        final first = browser.browse(const RemotePathQuery(directory: '/a'));
        final firstFailure = expectLater(first, failsWith(RemotePathFailure.cancelled));
        await pause();
        final second = await browser.browse(const RemotePathQuery(directory: '/b'));
        await firstFailure;
        expect(names(second), ['y']);
        expect(reader.aborted, 1);
        expect(reader.listed, ['/a', '/b']);
      });

      test('a listing that outlasts the timeout is aborted, reported, and not retried at once', () async {
        final reader = _Reader({
          '/slow': [file('x')],
        })..gates['/slow'] = Completer<void>();
        final browser = make(reader, timeout: const Duration(milliseconds: 40));
        const slow = RemotePathQuery(directory: '/slow');
        await expectLater(browser.browse(slow), failsWith(RemotePathFailure.timeout));
        expect(reader.aborted, 1);
        await expectLater(browser.browse(slow), failsWith(RemotePathFailure.timeout));
        expect(reader.listed, ['/slow']);
      });

      test('dispose stops what is running, closes the reader and refuses new queries', () async {
        final reader = _Reader({
          '/srv': [file('x')],
        })..gates['/srv'] = Completer<void>();
        final browser = RemotePathBrowser(reader, generation: 1);
        final pending = browser.browse(srv);
        final failure = expectLater(pending, failsWith(RemotePathFailure.unavailable));
        await pause();
        browser.dispose();
        browser.dispose();
        await failure;
        expect(reader.aborted, 1);
        expect(reader.closed, isTrue);
        await expectLater(browser.browse(srv), failsWith(RemotePathFailure.unavailable));
      });
    });
  });

  group('sftp reader', () {
    CancellationToken token() => CancellationToken();

    test('maps entries to kinds', () async {
      final fs = _Files(
        entries: [
          const FileEntry('d', FileKind.directory),
          const FileEntry('f', FileKind.file),
          const FileEntry('l', FileKind.link, linkToDir: true),
          const FileEntry('b', FileKind.link),
          const FileEntry('s', FileKind.other),
        ],
      );
      final reader = SftpDirectoryReader(() async => fs);
      addTearDown(reader.close);
      final listing = await reader.list('/x', token());
      expect(listing.complete, isTrue);
      expect(
        [for (final i in listing.items) (i.name, i.kind, i.linkToDirectory)],
        [
          ('d', RemotePathKind.directory, false),
          ('f', RemotePathKind.file, false),
          ('l', RemotePathKind.symlink, true),
          ('b', RemotePathKind.symlink, false),
          ('s', RemotePathKind.file, false),
        ],
      );
      expect(await reader.home(token()), '/home/u');
      expect(fs.listed, ['/x']);
    });

    test('opens one channel, reuses it, and closes it when idle', () async {
      var opens = 0;
      final fs = _Files();
      final reader = SftpDirectoryReader(() async {
        opens++;
        return fs;
      }, idle: const Duration(milliseconds: 30));
      addTearDown(reader.close);
      await reader.list('/a', token());
      await reader.list('/b', token());
      expect(opens, 1);
      expect(fs.closes, 0);
      await pause(100);
      expect(fs.closes, 1);
      await reader.list('/c', token());
      expect(opens, 2);
    });

    test('cancelling closes the channel; the next request opens a fresh one', () async {
      final channels = <_Files>[];
      final reader = SftpDirectoryReader(() async {
        final fs = _Files(gate: channels.isEmpty ? Completer<void>() : null);
        channels.add(fs);
        return fs;
      });
      addTearDown(reader.close);
      final cancel = token();
      final pending = reader.list('/slow', cancel);
      final failure = expectLater(pending, failsWith(RemotePathFailure.cancelled));
      await pause();
      expect(channels.single.closes, 0);
      cancel.cancel();
      await failure;
      await pause();
      expect(channels.first.closes, 1);
      expect((await reader.list('/ok', token())).items, isEmpty);
      expect(channels, hasLength(2));
      expect(channels.last.closes, 0);
    });

    test('a token that is already cancelled, a lost lease or a closed reader never open a channel', () async {
      var opens = 0;
      Future<FileSystem> open() async {
        opens++;
        return _Files();
      }

      final cancelled = token()..cancel();
      final reader = SftpDirectoryReader(open);
      await expectLater(reader.list('/x', cancelled), failsWith(RemotePathFailure.cancelled));
      reader.close();
      await expectLater(reader.home(token()), failsWith(RemotePathFailure.unavailable));
      final lost = SftpDirectoryReader(open, isLost: () => true);
      await expectLater(lost.list('/x', token()), failsWith(RemotePathFailure.unavailable));
      expect(opens, 0);
    });

    test('a channel that cannot be opened is unavailable and is tried again next time', () async {
      var attempts = 0;
      final reader = SftpDirectoryReader(() async {
        if (attempts++ == 0) throw StateError('no channel');
        return _Files();
      });
      addTearDown(reader.close);
      await expectLater(reader.list('/x', token()), failsWith(RemotePathFailure.unavailable));
      expect((await reader.list('/x', token())).items, isEmpty);
      expect(attempts, 2);

      final released = SftpDirectoryReader(() => throw StateError('lease already released'));
      await expectLater(released.list('/x', token()), failsWith(RemotePathFailure.unavailable));
      released.close();
    });

    test('file system failures become path failures', () async {
      for (final (error, expected) in [
        (const FsError(FsFailure.notFound), RemotePathFailure.notFound),
        (const FsError(FsFailure.permission), RemotePathFailure.denied),
        (const FsError(FsFailure.lost), RemotePathFailure.unavailable),
        (const FsError(FsFailure.failed), RemotePathFailure.failed),
      ]) {
        final reader = SftpDirectoryReader(() async => _Files(error: error));
        await expectLater(reader.list('/x', token()), failsWith(expected), reason: '${error.kind}');
        reader.close();
      }
    });

    group('bounded listing', () {
      (SftpDirectoryReader, List<_Bounded>) bounded(_Bounded Function(int channel) make) {
        final channels = <_Bounded>[];
        final reader = SftpDirectoryReader(() async {
          final fs = make(channels.length);
          channels.add(fs);
          return fs;
        });
        addTearDown(reader.close);
        return (reader, channels);
      }

      test('scans instead of listing, with the scan limit and the name filter, and keeps its channel', () async {
        final (reader, channels) = bounded(
          (_) => _Bounded(
            entries: [
              const FileEntry('ok', FileKind.file),
              const FileEntry('bad\nname', FileKind.file),
              const FileEntry('d', FileKind.directory),
              const FileEntry('l', FileKind.link, linkToDir: true),
            ],
          ),
        );
        final listing = await reader.list('/x', token());
        final fs = channels.single;
        expect(fs.scans, [('/x', RemotePaths.maxScanned)]);
        expect(fs.listed, isEmpty);
        expect(fs.accepted!('ok'), isTrue);
        expect(fs.accepted!('bad\nname'), isFalse);
        expect(listing.complete, isTrue);
        expect(
          [for (final i in listing.items) (i.name, i.kind, i.linkToDirectory)],
          [
            ('ok', RemotePathKind.file, false),
            ('d', RemotePathKind.directory, false),
            ('l', RemotePathKind.symlink, true),
          ],
        );
        await reader.list('/y', token());
        await pause();
        expect(channels, hasLength(1));
        expect(fs.closes, 0);
      });

      test('an incomplete scan is reported and its channel closed; the next request opens a fresh one', () async {
        final (reader, channels) = bounded(
          (n) => _Bounded(entries: [const FileEntry('a', FileKind.file)], complete: n > 0),
        );
        final first = await reader.list('/big', token());
        expect(first.complete, isFalse);
        expect(first.items.single.name, 'a');
        await pause();
        expect(channels.single.closes, 1, reason: 'the server still holds the directory open');
        expect((await reader.list('/small', token())).complete, isTrue);
        expect(channels, hasLength(2));
        await pause();
        expect(channels.last.closes, 0);
      });

      test('a failed scan closes the channel unless the directory simply could not be opened', () async {
        for (final (error, closes) in [
          (const FsError(FsFailure.failed), 1),
          (const FsError(FsFailure.lost), 1),
          (const FsError(FsFailure.notFound), 0),
          (const FsError(FsFailure.permission), 0),
        ]) {
          final (reader, channels) = bounded((_) => _Bounded(error: error));
          await expectLater(reader.list('/x', token()), throwsA(isA<RemotePathException>()));
          await pause();
          expect(channels.single.closes, closes, reason: '${error.kind}');
        }
      });

      test('cancelling a scan hands the token down and closes the channel', () async {
        final (reader, channels) = bounded((_) => _Bounded(gate: Completer<void>()));
        final cancel = token();
        final failure = expectLater(reader.list('/slow', cancel), failsWith(RemotePathFailure.cancelled));
        await pause();
        expect(channels.single.scanCancel, same(cancel));
        cancel.cancel();
        await failure;
        await pause();
        expect(channels.single.closes, 1);
      });

      test('without a scan it lists, cuts the list at the limit and says so, and keeps its channel', () async {
        List<FileEntry> files(int count) => [for (var i = 0; i < count; i++) FileEntry('f$i', FileKind.file)];
        final over = _Files(entries: files(RemotePaths.maxScanned + 5));
        final exact = _Files(entries: files(RemotePaths.maxScanned));
        final cut = SftpDirectoryReader(() async => over);
        final whole = SftpDirectoryReader(() async => exact);
        addTearDown(cut.close);
        addTearDown(whole.close);
        final cutListing = await cut.list('/x', token());
        expect(cutListing.items, hasLength(RemotePaths.maxScanned));
        expect(cutListing.items.last.name, 'f${RemotePaths.maxScanned - 1}');
        expect(cutListing.complete, isFalse);
        final wholeListing = await whole.list('/x', token());
        expect((wholeListing.items.length, wholeListing.complete), (RemotePaths.maxScanned, true));
        await pause();
        expect((over.closes, exact.closes), (0, 0), reason: 'read to the end, nothing is left open');
      });

      test('a request that outlasts the limit times out and closes its channel, listing or scanning', () async {
        final slows = <_Files Function()>[
          () => _Files(gate: Completer<void>()),
          () => _Bounded(gate: Completer<void>()),
        ];
        for (final slow in slows) {
          final channels = <_Files>[];
          final reader = SftpDirectoryReader(() async {
            final fs = channels.isEmpty ? slow() : _Files();
            channels.add(fs);
            return fs;
          }, limit: const Duration(milliseconds: 40));
          addTearDown(reader.close);
          await expectLater(reader.list('/slow', token()), failsWith(RemotePathFailure.timeout));
          await pause();
          expect(channels.first.closes, 1);
          expect((await reader.list('/ok', token())).items, isEmpty);
          expect(channels, hasLength(2));
        }
      });
    });

    group('a channel that opens late', () {
      test('is closed unused when the request was cancelled or timed out meanwhile', () async {
        for (final timeout in [false, true]) {
          final opening = Completer<FileSystem>();
          final fs = _Files();
          final reader = SftpDirectoryReader(() => opening.future, limit: Duration(milliseconds: timeout ? 40 : 3000));
          addTearDown(reader.close);
          final cancel = token();
          final failure = expectLater(
            reader.list('/x', cancel),
            failsWith(timeout ? RemotePathFailure.timeout : RemotePathFailure.cancelled),
          );
          if (!timeout) {
            await pause();
            cancel.cancel();
          }
          await failure;
          opening.complete(fs);
          await pause();
          expect(fs.listed, isEmpty, reason: 'timeout: $timeout');
          expect(fs.closes, 1, reason: 'timeout: $timeout');
        }
      });

      test('is closed unused when the reader was closed or the lease lost meanwhile', () async {
        for (final lose in [false, true]) {
          final opening = Completer<FileSystem>();
          final fs = _Files();
          var lost = false;
          final reader = SftpDirectoryReader(() => opening.future, isLost: () => lost);
          addTearDown(reader.close);
          final failure = expectLater(reader.list('/x', token()), failsWith(RemotePathFailure.unavailable));
          await pause();
          if (lose) {
            lost = true;
          } else {
            reader.close();
          }
          opening.complete(fs);
          await failure;
          await pause();
          expect(fs.listed, isEmpty, reason: 'lost: $lose');
          expect(fs.closes, 1, reason: 'lost: $lose');
        }
      });
    });

    test('close ends the channel it opened', () async {
      final fs = _Files();
      final reader = SftpDirectoryReader(() async => fs);
      await reader.list('/x', token());
      reader.close();
      await pause();
      expect(fs.closes, 1);
    });
  });

  group('sftp scan', () {
    Future<bool> never(String _) async => fail('no link should be looked at');
    List<String> entryNames(BoundedListing listing) => [for (final e in listing.entries) e.name];

    test('skips dot entries, keeps the order and tells files, directories and links apart', () async {
      final source = _Readdir([
        [sftpName('.', _dirMode), sftpName('..', _dirMode), sftpName('a'), sftpName('d', _dirMode)],
        [sftpName('l', _linkMode), sftpName('b')],
      ]);
      final listing = await scanSftpDirectory(
        source.stream,
        maxScanned: 10,
        linksToDirectory: (name) async => name == 'l',
      );
      expect(
        [for (final e in listing.entries) (e.name, e.kind, e.linkToDir)],
        [
          ('a', FileKind.file, false),
          ('d', FileKind.directory, false),
          ('l', FileKind.link, true),
          ('b', FileKind.file, false),
        ],
      );
      expect((listing.scanned, listing.complete, source.drained), (4, true, true));
    });

    test('stops at the first name past the limit and reads no further', () async {
      final source = _Readdir([
        [sftpName('a'), sftpName('b')],
        [sftpName('c'), sftpName('d')],
        [sftpName('e')],
      ]);
      final listing = await scanSftpDirectory(source.stream, maxScanned: 3, linksToDirectory: never);
      expect(entryNames(listing), ['a', 'b', 'c']);
      expect((listing.scanned, listing.complete), (3, false));
      expect((source.pulled, source.drained), (2, false));
    });

    test('exactly the limit is complete once the directory ends', () async {
      final source = _Readdir([
        [sftpName('a'), sftpName('b')],
        [sftpName('c')],
      ]);
      final listing = await scanSftpDirectory(source.stream, maxScanned: 3, linksToDirectory: never);
      expect((listing.scanned, listing.complete, source.drained), (3, true, true));
    });

    test('dot entries do not count against the limit', () async {
      final source = _Readdir([
        [sftpName('.'), sftpName('..'), sftpName('a'), sftpName('b')],
      ]);
      final listing = await scanSftpDirectory(source.stream, maxScanned: 2, linksToDirectory: never);
      expect(entryNames(listing), ['a', 'b']);
      expect(listing.complete, isTrue);
    });

    test('refused names count as scanned but are neither kept nor looked at', () async {
      final looked = <String>[];
      final source = _Readdir([
        [sftpName('keep'), sftpName('skip'), sftpName('skiplink', _linkMode), sftpName('keeplink', _linkMode)],
      ]);
      final listing = await scanSftpDirectory(
        source.stream,
        maxScanned: 10,
        accept: (name) => !name.startsWith('skip'),
        linksToDirectory: (name) async {
          looked.add(name);
          return true;
        },
      );
      expect(entryNames(listing), ['keep', 'keeplink']);
      expect(listing.scanned, 4);
      expect(looked, ['keeplink']);
      expect(listing.entries.last.linkToDir, isTrue);
    });

    test('refused names still count toward the limit', () async {
      final source = _Readdir([
        [sftpName('x1'), sftpName('x2'), sftpName('a'), sftpName('b')],
      ]);
      final listing = await scanSftpDirectory(
        source.stream,
        maxScanned: 3,
        accept: (name) => !name.startsWith('x'),
        linksToDirectory: never,
      );
      expect(entryNames(listing), ['a']);
      expect((listing.scanned, listing.complete), (3, false));
    });

    test('looks at links 16 at a time and none past the limit', () async {
      var active = 0, peak = 0;
      final looked = <String>[];
      final source = _Readdir([
        [for (var i = 0; i < 50; i++) sftpName('l$i', _linkMode)],
      ]);
      final listing = await scanSftpDirectory(
        source.stream,
        maxScanned: 40,
        linksToDirectory: (name) async {
          looked.add(name);
          active++;
          if (active > peak) peak = active;
          await pause(1);
          active--;
          return int.parse(name.substring(1)).isEven;
        },
      );
      expect(looked, hasLength(40));
      expect(looked, isNot(contains('l40')));
      expect(peak, 16);
      expect(listing.complete, isFalse);
      expect(listing.entries.where((e) => e.linkToDir), hasLength(20));
    });

    test('a link lookup that fails fails the scan', () async {
      final source = _Readdir([
        [sftpName('l', _linkMode)],
      ]);
      await expectLater(
        scanSftpDirectory(
          source.stream,
          maxScanned: 10,
          linksToDirectory: (_) async => throw const FsError(FsFailure.lost),
        ),
        throwsA(isA<FsError>().having((e) => e.kind, 'kind', FsFailure.lost)),
      );
    });

    test('cancelling is noticed between batches and stops reading', () async {
      final cancel = CancellationToken();
      final source = _Readdir(
        [
          [sftpName('a')],
          [sftpName('b')],
          [sftpName('c')],
        ],
        onPull: (pulled) {
          if (pulled == 2) cancel.cancel();
        },
      );
      await expectLater(
        scanSftpDirectory(source.stream, maxScanned: 10, cancel: cancel, linksToDirectory: never),
        throwsA(isA<FsError>()),
      );
      expect((source.pulled, source.drained), (2, false));
    });

    test('cancelling is noticed between windows of link lookups', () async {
      final cancel = CancellationToken();
      var looked = 0;
      final source = _Readdir([
        [for (var i = 0; i < 40; i++) sftpName('l$i', _linkMode)],
      ]);
      await expectLater(
        scanSftpDirectory(
          source.stream,
          maxScanned: 100,
          cancel: cancel,
          linksToDirectory: (_) async {
            looked++;
            cancel.cancel();
            return false;
          },
        ),
        throwsA(isA<FsError>()),
      );
      expect(looked, 16);
    });
  });

  group('lease', () {
    const host = Host(id: HostId('h'), label: 'h', address: 'example.com', username: 'u');

    test('reads through the lease it was given, leaves it to its owner and dials nothing', () async {
      final files = _Files(
        entries: [const FileEntry('src', FileKind.directory), const FileEntry('a.txt', FileKind.file)],
      );
      final server = _Server(files);
      var dials = 0;
      final manager = ConnectionManager((_, _, _) async {
        dials++;
        return server;
      }, park: Duration.zero);
      addTearDown(manager.closeAll);
      final lease = await manager.acquire(host, NoPrompts());
      final source = LeaseRemotePathSource(lease, generation: 3);
      final result = await source.browse(const RemotePathQuery(directory: '/srv'));
      expect(names(result), ['src', 'a.txt']);
      expect(result.generation, 3);
      expect(server.opened, 1);
      expect(files.listed, ['/srv']);

      source.dispose();
      await pause();
      expect(files.closes, 1);
      expect(lease.lost, isFalse, reason: 'the lease and its transport are the owner\'s');
      expect(dials, 1);

      lease.release();
      final stale = LeaseRemotePathSource(lease, generation: 4);
      await expectLater(
        stale.browse(const RemotePathQuery(directory: '/srv')),
        failsWith(RemotePathFailure.unavailable),
      );
      stale.dispose();
      expect(dials, 1);
    });

    test('scans through the lease, reports a cut-off directory as truncated and closes only its channel', () async {
      final files = _Bounded(entries: [const FileEntry('src', FileKind.directory)], complete: false);
      final server = _Server(files);
      final manager = ConnectionManager((_, _, _) async => server, park: Duration.zero);
      addTearDown(manager.closeAll);
      final lease = await manager.acquire(host, NoPrompts());
      final source = LeaseRemotePathSource(lease, generation: 1);
      addTearDown(source.dispose);
      final result = await source.browse(const RemotePathQuery(directory: '/big'));
      expect(names(result), ['src']);
      expect(result.truncated, isTrue);
      expect(files.scans, [('/big', RemotePaths.maxScanned)]);
      expect(files.listed, isEmpty);
      await pause();
      expect(files.closes, 1);
      expect(lease.lost, isFalse);
      await source.browse(const RemotePathQuery(directory: '/other'));
      expect(server.opened, 2, reason: 'a fresh channel after the cut-off scan');
    });
  });
}
