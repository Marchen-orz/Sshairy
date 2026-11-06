import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/adapters/local_fs.dart';
import 'package:sshairy/features/files/application/file_ops.dart';
import 'package:sshairy/features/files/application/file_systems.dart';
import 'package:sshairy/features/files/application/transfers.dart';
import 'package:sshairy/features/files/domain/transfer.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';

class NoDial implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.reject;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

/// Answers every conflict with [answer] and records what was asked.
class FakeUi implements TransferUi {
  FakeUi(this.answer);

  ConflictAnswer? answer;
  final asked = <ConflictKind>[];
  Completer<void>? hold;

  @override
  ConnectPrompts get prompts => NoDial();

  @override
  Future<ConflictAnswer?> conflict(Transfer transfer, Conflict conflict, CancellationToken cancel) async {
    asked.add(conflict.kind);
    await hold?.future;
    return answer;
  }
}

void main() {
  group('PathStyle', () {
    test('posix', () {
      const p = PathStyle.posix;
      expect(p.join('/home/u', 'a b'), '/home/u/a b');
      expect(p.join('/', 'etc'), '/etc');
      expect(p.parent('/home/u'), '/home');
      expect(p.parent('/home'), '/');
      expect(p.parent('/'), '/');
      expect(p.name('/home/u/'), 'u');
      expect(p.crumbs('/home/u').map((c) => c.$2), ['/', '/home', '/home/u']);
      // A backslash is an ordinary character in a POSIX name.
      expect(p.name(r'/tmp/a\b'), r'a\b');
    });

    test('windows', () {
      const w = PathStyle.windows;
      expect(w.join(r'C:\', 'Users'), r'C:\Users');
      expect(w.join(r'C:\Users', 'x'), r'C:\Users\x');
      expect(w.parent(r'C:\Users\x'), r'C:\Users');
      expect(w.parent(r'C:\Users'), r'C:\');
      expect(w.parent(r'C:\'), '');
      expect(w.name(r'C:\Users\x\'), 'x');
      expect(w.crumbs(r'C:\Users').map((c) => c.$2), ['', r'C:\', r'C:\Users']);
    });
  });

  test('keep-both names', () {
    expect(keepBothName('report.pdf', 1, directory: false), 'report (1).pdf');
    expect(keepBothName('.bashrc', 2, directory: false), '.bashrc (2)');
    expect(keepBothName('photos.2024', 1, directory: true), 'photos.2024 (1)');
    expect(keepBothName('Makefile', 3, directory: false), 'Makefile (3)');
  });

  test('bad names', () {
    expect(badName('a/b', PathStyle.posix), isNotNull);
    expect(badName('..', PathStyle.posix), isNotNull);
    expect(badName('a:b', PathStyle.posix), isNull);
    expect(badName('a:b', PathStyle.windows), isNotNull);
    expect(badName('中文 名.txt', PathStyle.windows), isNull);
  });

  group('transfer model', () {
    Transfer t(String id, {String? src, String? dst, String path = '/x', TransferState s = TransferState.queued, DateTime? at}) =>
        Transfer(
          id: TransferId(id),
          batch: 'b',
          source: FileEnd(src == null ? null : HostId(src), '/s/$id'),
          target: FileEnd(dst == null ? null : HostId(dst), path == '/x' ? '/t/$id' : path),
          created: at ?? DateTime(2026),
          state: s,
          finished: s.active ? null : at,
        );

    test('runnable respects global, per-host and target limits', () {
      final all = [
        t('1', dst: 'h'),
        t('2', dst: 'h'),
        t('3', dst: 'h'),
        t('4', dst: 'g', path: '/same'),
        t('5', dst: 'g', path: '/same'),
        t('6'),
      ];
      expect(runnable(all, global: 8).map((i) => i.value), ['1', '2', '4', '6']);
      expect(runnable(all, global: 2).map((i) => i.value), ['1', '2']);
      final busy = [t('1', dst: 'h', s: TransferState.waiting), ...all.skip(1)];
      expect(runnable(busy, global: 8).map((i) => i.value), ['2', '4', '6']);
    });

    test('saved active transfers come back interrupted; history is pruned', () {
      final running = t('r', dst: 'h', s: TransferState.running);
      final back = Transfer.fromJson(jsonDecode(jsonEncode(running.toJson())) as Map<String, dynamic>);
      expect(back.state, TransferState.interrupted);
      expect(back.target.host, HostId('h'));

      final now = DateTime(2026, 6, 1);
      final all = [
        t('old', s: TransferState.completed, at: now.subtract(const Duration(days: 31))),
        for (var i = 0; i < 5; i++) t('d$i', s: TransferState.completed, at: now.subtract(Duration(hours: i))),
        t('q'),
      ];
      expect(pruneHistory(all, now, max: 3).map((x) => x.id.value), ['d0', 'd1', 'd2', 'q']);
    });

    test('speed over a window', () {
      final m = SpeedMeter();
      final t0 = DateTime(2026);
      m.add(t0, 0);
      m.add(t0.add(const Duration(seconds: 1)), 1000);
      m.add(t0.add(const Duration(seconds: 2)), 3000);
      expect(m.bytesPerSecond, 1500);
    });
  });

  group('local file system', () {
    late Directory dir;
    const fs = LocalFileSystem();
    setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-fs'));
    tearDown(() => dir.deleteSync(recursive: true));
    String at(String name) => fs.style.join(dir.path, name);

    test('writes through a part file and never overwrites by accident', () async {
      await writeVerified(fs, at('a.txt'), Stream.value(utf8.encode('hello')), expectedSize: 5);
      expect(File(at('a.txt')).readAsStringSync(), 'hello');
      expect(dir.listSync().map((e) => fs.style.name(e.path)), ['a.txt']);

      await expectLater(
        writeVerified(fs, at('a.txt'), Stream.value(utf8.encode('other'))),
        throwsA(isA<FsError>().having((e) => e.kind, 'kind', FsFailure.exists)),
      );
      expect(File(at('a.txt')).readAsStringSync(), 'hello');
      expect(dir.listSync(), hasLength(1), reason: 'the part file is cleaned up');

      await expectLater(
        writeVerified(fs, at('b.txt'), Stream.value(utf8.encode('abc')), expectedSize: 4),
        throwsA(isA<OpFailure>().having((e) => e.code, 'code', 'sizeMismatch')),
      );
      expect(File(at('b.txt')).existsSync(), isFalse);
    });

    test('replaces only the file it was told about', () async {
      File(at('a.txt')).writeAsStringSync('v1');
      final seen = (await fs.stat(at('a.txt')))!;
      await writeVerified(fs, at('a.txt'), Stream.value(utf8.encode('v2')), replacing: seen);
      expect(File(at('a.txt')).readAsStringSync(), 'v2');

      final stale = FileEntry('a.txt', FileKind.file, size: 99, modified: seen.modified);
      await expectLater(
        writeVerified(fs, at('a.txt'), Stream.value(utf8.encode('v3')), replacing: stale),
        throwsA(isA<OpFailure>().having((e) => e.code, 'code', 'targetChanged')),
      );
      expect(File(at('a.txt')).readAsStringSync(), 'v2');
      expect(dir.listSync(), hasLength(1));
    });

    test('lists, stats, renames and deletes trees', () async {
      Directory(at('d/e')).createSync(recursive: true);
      File(at('d/e/f.txt')).writeAsStringSync('x');
      File(at('d/g.txt')).writeAsStringSync('yy');
      final names = (await fs.list(at('d'))).map((e) => e.name).toSet();
      expect(names, {'e', 'g.txt'});
      expect((await fs.stat(at('d/g.txt')))?.size, 2);
      expect(await fs.stat(at('missing')), isNull);
      await expectLater(fs.mkdir(at('d')), throwsA(isA<FsError>()));
      await expectLater(fs.rename(at('d/g.txt'), at('d/e')), throwsA(isA<FsError>()));
      final d = (await fs.stat(at('d')))!;
      expect(await countTree(fs, at('d'), d), 4);
      await deleteTree(fs, at('d'), d);
      expect(await fs.stat(at('d')), isNull);
    });
  });

  group('TransferManager', () {
    late Directory dir;
    late ProviderContainer c;
    late FakeUi ui;
    String at(String name) => '${dir.path}${Platform.pathSeparator}$name';

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sshairy-tr');
      Directory(at('src/sub')).createSync(recursive: true);
      Directory(at('dst')).createSync();
      File(at('src/a.txt')).writeAsStringSync('alpha');
      File(at('src/sub/b.txt')).writeAsStringSync('bravo!');
      c = ProviderContainer(overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        fileSystemsProvider.overrideWithValue(FileSystems(ConnectionManager((_, _, _) => throw StateError('no')), (_) => null)),
      ]);
      ui = FakeUi(const ConflictAnswer(ConflictChoice.replace));
      c.read(transfersProvider.notifier).ui = ui;
    });
    tearDown(() async {
      await c.read(transfersProvider.notifier).saved;
      c.dispose();
      dir.deleteSync(recursive: true);
    });

    TransferManager manager() => c.read(transfersProvider.notifier);

    Future<List<Transfer>> settle() async {
      for (var i = 0; i < 500 && c.read(transfersProvider).any((t) => t.state.active); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return c.read(transfersProvider);
    }

    test('copies a file and a directory', () async {
      manager().enqueue(from: null, paths: [at('src/a.txt'), at('src/sub')], to: null, targetDir: at('dst'));
      final done = await settle();
      expect(done.map((t) => t.state), everyElement(TransferState.completed));
      expect(File(at('dst/a.txt')).readAsStringSync(), 'alpha');
      expect(File(at('dst/sub/b.txt')).readAsStringSync(), 'bravo!');
      expect(done.last.totalFiles, 1);
      await manager().saved;
      final saved = File(at('transfers.json')).readAsStringSync();
      expect(jsonDecode(saved)['transfers'], hasLength(2));
    });

    test('conflicts: keep both, skip, replace for the rest of the batch', () async {
      File(at('dst/a.txt')).writeAsStringSync('old');
      ui.answer = const ConflictAnswer(ConflictChoice.keepBoth);
      manager().enqueue(from: null, paths: [at('src/a.txt')], to: null, targetDir: at('dst'));
      await settle();
      expect(File(at('dst/a (1).txt')).readAsStringSync(), 'alpha');
      expect(File(at('dst/a.txt')).readAsStringSync(), 'old');

      ui.answer = const ConflictAnswer(ConflictChoice.skip);
      manager().enqueue(from: null, paths: [at('src/a.txt')], to: null, targetDir: at('dst'));
      final skipped = (await settle()).last;
      expect(skipped.state, TransferState.completed);
      expect(skipped.skipped, 1);
      expect(File(at('dst/a.txt')).readAsStringSync(), 'old');

      // Merging a directory, then replacing every clashing file in it after one answer.
      Directory(at('dst/sub')).createSync();
      File(at('dst/sub/b.txt')).writeAsStringSync('old');
      final scripted = _Scripted([
        const ConflictAnswer(ConflictChoice.merge),
        const ConflictAnswer(ConflictChoice.replace, all: true),
      ]);
      manager().ui = scripted;
      manager().enqueue(from: null, paths: [at('src/sub')], to: null, targetDir: at('dst'));
      expect((await settle()).last.state, TransferState.completed);
      expect(scripted.asked, [ConflictKind.directory, ConflictKind.file]);
      expect(File(at('dst/sub/b.txt')).readAsStringSync(), 'bravo!');
      expect(Directory(at('dst/sub')).listSync(), hasLength(1), reason: 'no part files left');
    });

    test('cancel while asking leaves the target alone; retry starts over', () async {
      File(at('dst/a.txt')).writeAsStringSync('old');
      ui.hold = Completer<void>();
      final id = manager().enqueue(from: null, paths: [at('src/a.txt')], to: null, targetDir: at('dst')).single;
      for (var i = 0; i < 100 && manager().byId(id)?.state != TransferState.waiting; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(manager().byId(id)?.state, TransferState.waiting);
      manager().cancel(id);
      expect((await settle()).single.state, TransferState.cancelled);
      expect(File(at('dst/a.txt')).readAsStringSync(), 'old');

      ui.hold = null;
      manager().retry(id);
      expect((await settle()).single.state, TransferState.completed);
      expect(File(at('dst/a.txt')).readAsStringSync(), 'alpha');
    });

    test('a missing source fails with a code', () async {
      manager().enqueue(from: null, paths: [at('src/none')], to: null, targetDir: at('dst'));
      final t = (await settle()).single;
      expect(t.state, TransferState.failed);
      expect(t.error, 'sourceMissing');
    });
  });
}

class _Scripted implements TransferUi {
  _Scripted(this.answers);

  final List<ConflictAnswer> answers;
  final asked = <ConflictKind>[];

  @override
  ConnectPrompts get prompts => NoDial();

  @override
  Future<ConflictAnswer?> conflict(Transfer transfer, Conflict conflict, CancellationToken cancel) async {
    asked.add(conflict.kind);
    return answers.removeAt(0);
  }
}
