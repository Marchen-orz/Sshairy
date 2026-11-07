import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/configuration.dart';
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
    Transfer t(
      String id, {
      String? src,
      String? dst,
      String path = '/x',
      TransferState s = TransferState.queued,
      DateTime? at,
    }) => Transfer(
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
      // A parked or stranded transfer holds its target without taking a slot.
      final parked = [t('1', dst: 'h', path: '/same', s: TransferState.paused), t('2', dst: 'h', path: '/same')];
      expect(runnable(parked, global: 8), isEmpty);
      final stranded = [
        Transfer(
          id: TransferId('1'),
          batch: 'b',
          source: FileEnd(null, '/s'),
          target: FileEnd(HostId('h'), '/same'),
          created: DateTime(2026),
          state: TransferState.interrupted,
          checkpoint: TransferCheckpoint(
            offset: 1,
            source: FileEntry('s', FileKind.file, size: 2),
            target: '/same',
            part: '/.same.1.part',
          ),
        ),
        t('2', dst: 'h', path: '/same'),
      ];
      expect(runnable(stranded, global: 8), isEmpty);
    });

    test('saved active transfers come back interrupted; history is pruned', () {
      final running = t('r', dst: 'h', s: TransferState.running);
      final back = Transfer.fromJson(jsonDecode(jsonEncode(running.toJson())) as Map<String, dynamic>);
      expect(back.state, TransferState.interrupted);
      expect(back.target.host, HostId('h'));

      final now = DateTime(2026, 6, 1);
      final all = [
        t('old', s: TransferState.completed, at: now.subtract(const Duration(days: 31))),
        for (var i = 0; i < 5; i++)
          t(
            'd$i',
            s: TransferState.completed,
            at: now.subtract(Duration(hours: i)),
          ),
        t('q'),
      ];
      expect(pruneHistory(all, now, max: 3).map((x) => x.id.value), ['d0', 'd1', 'd2', 'q']);
    });

    test('every allocated keep-both suffix is resumable on both path styles', () {
      for (final style in PathStyle.values) {
        final root = style == PathStyle.windows ? r'C:\dst' : '/dst';
        for (final name in ['a.txt', '.bashrc', 'Makefile', 'archive.tar.gz', '中文 名.txt']) {
          final original = style.join(root, name);
          final transfer = t('safe-id', path: original);
          for (final n in [1, 2, 9, 10, 11, 99, 100, 101, 999, 1000]) {
            final actual = style.join(root, keepBothName(name, n, directory: false));
            final cp = TransferCheckpoint(
              offset: 2,
              source: FileEntry(name, FileKind.file, size: 4),
              target: actual,
              part: partPathFor(style, actual, transfer.id),
              settled: true,
            );
            expect(checkpointProblem(transfer, cp, style), n < 1000 ? isNull : 'partInvalid', reason: '$style $actual');
            expect(partDerived(transfer, cp, style), n < 1000, reason: 'cleanup: $actual');
          }
        }
      }
    });

    test('unsafe historical IDs cannot create or own a part on either path style', () {
      for (final style in PathStyle.values) {
        final target = style == PathStyle.windows ? r'C:\safe\a.txt' : '/safe/a.txt';
        for (final id in ['', 'x/../../outside', r'x\..\..\outside', '..', 'x:y', 'x\u0000y', 'x\ny', 'a' * 129]) {
          final transfer = t(id, path: target);
          final cp = TransferCheckpoint(
            offset: 1,
            source: FileEntry('a.txt', FileKind.file, size: 2),
            target: target,
            part: style.join(style.parent(target), '.a.txt.$id.part'),
            settled: true,
          );
          expect(partDerived(transfer, cp, style), isFalse);
          expect(checkpointProblem(transfer, cp, style), 'partInvalid');
          expect(() => partPathFor(style, target, transfer.id), throwsFormatException);
          expect(() => Transfer.fromJson(transfer.copyWith(checkpoint: () => cp).toJson()), throwsFormatException);
        }
      }
    });

    test('speed over a window', () {
      final m = SpeedMeter();
      final t0 = DateTime(2026);
      m.add(t0, 0);
      m.add(t0.add(const Duration(seconds: 1)), 1000);
      m.add(t0.add(const Duration(seconds: 2)), 3000);
      expect(m.bytesPerSecond, 1500);
    });

    test('speed keeps a bounded number of samples at block rate', () {
      final m = SpeedMeter();
      final t0 = DateTime(2026);
      // 32 KiB every millisecond for ten seconds: about 32 MB/s.
      for (var i = 0; i <= 10000; i++) {
        m.add(t0.add(Duration(milliseconds: i)), i * 32768);
      }
      expect(m.sampleCount, lessThanOrEqualTo(32), reason: 'one per 100 ms over the 3 s window');
      expect(m.bytesPerSecond, closeTo(32768000, 32768000 * .01));
    });

    test('checkpoints round-trip and only resume paths the transfer owns', () {
      final t = Transfer(
        id: TransferId('own'),
        batch: 'b',
        source: FileEnd(HostId('g'), '/s/a'),
        target: FileEnd(HostId('h'), '/dst/a.txt'),
        created: DateTime(2026),
      );
      final cp = TransferCheckpoint(
        offset: 3,
        source: FileEntry('a.txt', FileKind.file, size: 5),
        target: '/dst/a.txt',
        part: partPathFor(PathStyle.posix, '/dst/a.txt', t.id),
        settled: true,
      );
      final back = Transfer.fromJson(
        (jsonDecode(jsonEncode(t.copyWith(checkpoint: () => cp).toJson())) as Map).cast<String, dynamic>(),
      );
      expect(back.checkpoint?.offset, 3);
      expect(back.checkpoint?.replacing, isNull);
      expect(checkpointProblem(back, back.checkpoint!, PathStyle.posix), isNull);
      // Unsettled, beyond the source, or naming a file that is not this transfer's own part.
      expect(checkpointProblem(back, cp.copyWith(settled: false), PathStyle.posix), 'partInvalid');
      expect(checkpointProblem(back, cp.copyWith(offset: 6), PathStyle.posix), 'partInvalid');
      expect(
        checkpointProblem(
          back,
          TransferCheckpoint(offset: 3, source: cp.source, target: '/dst/a.txt', part: '/etc/passwd', settled: true),
          PathStyle.posix,
        ),
        'partInvalid',
      );
      expect(
        checkpointProblem(
          back,
          TransferCheckpoint(
            offset: 3,
            source: cp.source,
            target: '/elsewhere/a.txt',
            part: partPathFor(PathStyle.posix, '/elsewhere/a.txt', t.id),
            settled: true,
          ),
          PathStyle.posix,
        ),
        'partInvalid',
      );
      // A keep-both name in the same directory is still the transfer's own target.
      expect(
        checkpointProblem(
          back,
          TransferCheckpoint(
            offset: 3,
            source: cp.source,
            target: '/dst/a (1).txt',
            part: partPathFor(PathStyle.posix, '/dst/a (1).txt', t.id),
            settled: true,
          ),
          PathStyle.posix,
        ),
        isNull,
      );
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

    test('a pause parks the copy: drained, kept, unpublished', () async {
      final pause = CancellationToken();
      final data = StreamController<Uint8List>();
      final part = at('.p.bin.staged');
      final writing = writeVerified(fs, at('p.bin'), data.stream, expectedSize: 10, part: part, pause: pause);
      data.add(utf8.encode('hello'));
      pause.cancel();
      await data.close();
      await expectLater(writing, throwsA(isA<Paused>().having((p) => p.written, 'written', 5)));
      expect(File(part).readAsStringSync(), 'hello');
      expect(File(at('p.bin')).existsSync(), isFalse);
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
      c = ProviderContainer(
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          fileSystemsProvider.overrideWithValue(
            FileSystems(ConnectionManager((_, _, _) => throw StateError('no')), (_) => null),
          ),
        ],
      );
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

    Future<Transfer> waitFor(TransferId id, TransferState s) async {
      for (var i = 0; i < 500 && manager().byId(id)?.state != s; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final t = manager().byId(id)!;
      expect(t.state, s);
      return t;
    }

    ProviderContainer fresh() => ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        fileSystemsProvider.overrideWithValue(
          FileSystems(ConnectionManager((_, _, _) => throw StateError('no')), (_) => null),
        ),
      ],
    );

    /// A paused transfer in transfers.json, with [offset] bytes of [bytes] already in its part file.
    TransferId craftPark(int offset, List<int> bytes, {bool settled = true}) {
      File(at('src/big.bin')).writeAsBytesSync(bytes);
      final id = TransferId('parked-$offset-${settled ? '' : 'x'}');
      final target = at('dst/big.bin');
      final part = partPathFor(TransferManager.styleOf(null), target, id);
      File(part).writeAsBytesSync(bytes.sublist(0, offset));
      final s = FileStat.statSync(at('src/big.bin'));
      File(at('transfers.json')).writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'transfers': [
            Transfer(
              id: id,
              batch: 'b',
              source: FileEnd(null, at('src/big.bin')),
              target: FileEnd(null, target),
              created: DateTime.now(),
              state: TransferState.paused,
              checkpoint: TransferCheckpoint(
                offset: offset,
                source: FileEntry('big.bin', FileKind.file, size: s.size, modified: s.modified),
                target: target,
                part: part,
                settled: settled,
              ),
            ).toJson(),
          ],
        }),
      );
      return id;
    }

    test('invalid recovery records preserve history and enter the configuration gate', () {
      for (final invalidId in [true, false]) {
        craftPark(2, [1, 2, 3]);
        final history = (jsonDecode(File(at('transfers.json')).readAsStringSync()) as Map).cast<String, dynamic>();
        final transfer = history['transfers'][0] as Map;
        if (invalidId) {
          transfer['id'] = 'x/../../outside';
        } else {
          (transfer['checkpoint'] as Map)['offset'] = 'not a length';
        }
        final original = jsonEncode(history);
        File(at('transfers.json')).writeAsStringSync(original);
        final c2 = fresh();
        try {
          expect(c2.read(configurationCheckProvider)?.file, 'transfers.json');
          expect(File(at('transfers.json')).readAsStringSync(), original);
          expect(File(at('dst/big.bin')).existsSync(), isFalse);
        } finally {
          c2.dispose();
        }
      }
    });

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

    test('pause parks a file at a stable length; resume finishes it', () async {
      final bytes = List<int>.generate(300000, (i) => i & 0xff);
      File(at('src/big.bin')).writeAsBytesSync(bytes);
      final id = manager().enqueue(from: null, paths: [at('src/big.bin')], to: null, targetDir: at('dst')).single;
      manager().pause(id);
      final parked = await waitFor(id, TransferState.paused);
      expect(parked.checkpoint?.settled, isTrue);
      expect(File(parked.checkpoint!.part).lengthSync(), parked.checkpoint!.offset);
      expect(File(parked.checkpoint!.part).lengthSync(), lessThanOrEqualTo(bytes.length));
      expect(File(at('dst/big.bin')).existsSync(), isFalse);
      await manager().saved;
      final saved = (jsonDecode(File(at('transfers.json')).readAsStringSync()) as Map)['transfers'] as List;
      expect(Transfer.fromJson((saved.single as Map).cast()).checkpoint?.settled, isTrue);

      manager().resume(id);
      final done = await waitFor(id, TransferState.completed);
      expect(done.bytes, bytes.length);
      expect(File(at('dst/big.bin')).readAsBytesSync(), bytes);
      expect(File(parked.checkpoint!.part).existsSync(), isFalse, reason: 'no part left');
    });

    test('a settled checkpoint survives a restart and resumes from its offset', () async {
      final bytes = List<int>.generate(100000, (i) => (i * 7) & 0xff);
      final id = craftPark(40000, bytes);
      final part = partPathFor(TransferManager.styleOf(null), at('dst/big.bin'), id);
      final c2 = fresh();
      addTearDown(c2.dispose);
      final restored = c2.read(transfersProvider).single;
      expect(restored.state, TransferState.interrupted);
      expect(restored.checkpoint?.offset, 40000);
      final m2 = c2.read(transfersProvider.notifier)..ui = ui;
      m2.resume(restored.id);
      for (var i = 0; i < 500 && c2.read(transfersProvider).single.state.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final done = c2.read(transfersProvider).single;
      expect(done.state, TransferState.completed);
      expect(File(at('dst/big.bin')).readAsBytesSync(), bytes);
      expect(File(part).existsSync(), isFalse);
      await m2.saved;
    });

    test('a changed source or a moved part refuses to resume', () async {
      final bytes = List<int>.generate(100000, (i) => i & 0xff);
      craftPark(40000, bytes);
      File(at('src/big.bin')).writeAsBytesSync(bytes.sublist(0, 60000));
      final c2 = fresh();
      addTearDown(c2.dispose);
      final m2 = c2.read(transfersProvider.notifier)..ui = ui;
      final first = c2.read(transfersProvider).single;
      m2.resume(first.id);
      for (var i = 0; i < 500 && c2.read(transfersProvider).single.state.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final refused = c2.read(transfersProvider).single;
      expect(refused.state, TransferState.failed);
      expect(refused.error, 'sourceChanged');
      expect(refused.checkpoint, isNotNull, reason: 'kept so remove/retry can clean the part');
      expect(File(at('dst/big.bin')).existsSync(), isFalse);
      await m2.saved;
      c2.dispose();

      // A part that no longer matches its checkpoint is just as refused.
      final id2 = craftPark(40000, bytes);
      final part2 = partPathFor(TransferManager.styleOf(null), at('dst/big.bin'), id2);
      File(part2).writeAsBytesSync(bytes.sublist(0, 20000));
      final c3 = fresh();
      addTearDown(c3.dispose);
      final m3 = c3.read(transfersProvider.notifier)..ui = ui;
      m3.resume(c3.read(transfersProvider).single.id);
      for (var i = 0; i < 500 && c3.read(transfersProvider).single.state.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final invalid = c3.read(transfersProvider).single;
      expect(invalid.state, TransferState.failed);
      expect(invalid.error, 'partInvalid');
      await m3.saved;
    });

    test('a file replaced by a directory fails before copying and keeps its part', () async {
      final bytes = List<int>.generate(100, (i) => i);
      final id = craftPark(40, bytes);
      final part = partPathFor(TransferManager.styleOf(null), at('dst/big.bin'), id);
      File(at('src/big.bin')).deleteSync();
      Directory(at('src/big.bin')).createSync();
      File(at('src/big.bin/child.txt')).writeAsStringSync('new directory content');
      final c2 = fresh();
      addTearDown(c2.dispose);
      final m2 = c2.read(transfersProvider.notifier)..ui = ui;
      m2.resume(id);
      for (var i = 0; i < 500 && m2.byId(id)!.state.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(m2.byId(id)!.state, TransferState.failed);
      expect(m2.byId(id)!.error, 'sourceChanged');
      expect(m2.byId(id)!.checkpoint, isNotNull);
      expect(File(part).readAsBytesSync(), bytes.sublist(0, 40));
      expect(Directory(at('dst/big.bin')).existsSync(), isFalse);
      expect(ui.asked, isEmpty);
      await m2.remove(id);
      expect(File(part).existsSync(), isFalse);
      expect(m2.byId(id), isNull);
      await m2.saved;
    });

    test('later keep-both targets resume and clean up without touching existing copies', () async {
      final bytes = List<int>.generate(100, (i) => i);
      for (final resume in [true, false]) {
        final id = craftPark(40, bytes);
        final style = TransferManager.styleOf(null);
        final original = at('dst/big.bin');
        final actual = at('dst/big (2).bin');
        final oldPart = partPathFor(style, original, id);
        final part = partPathFor(style, actual, id);
        File(oldPart).renameSync(part);
        File(original).writeAsStringSync('original');
        File(at('dst/big (1).bin')).writeAsStringSync('first copy');
        final history = (jsonDecode(File(at('transfers.json')).readAsStringSync()) as Map).cast<String, dynamic>();
        final checkpoint = history['transfers'][0]['checkpoint'] as Map;
        checkpoint['target'] = actual;
        checkpoint['part'] = part;
        File(at('transfers.json')).writeAsStringSync(jsonEncode(history));
        final c2 = fresh();
        final m2 = c2.read(transfersProvider.notifier)..ui = ui;
        try {
          if (resume) {
            m2.resume(id);
            for (var i = 0; i < 500 && m2.byId(id)!.state.active; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(m2.byId(id)!.state, TransferState.completed);
            expect(File(actual).readAsBytesSync(), bytes);
          } else {
            await m2.remove(id);
            expect(m2.byId(id), isNull);
          }
          expect(File(part).existsSync(), isFalse);
          expect(File(original).readAsStringSync(), 'original');
          expect(File(at('dst/big (1).bin')).readAsStringSync(), 'first copy');
          await m2.saved;
        } finally {
          c2.dispose();
        }
      }
    });

    test('an unsettled checkpoint is not resumable; retry starts over and cleans up', () async {
      final bytes = List<int>.generate(100000, (i) => i & 0xff);
      final id = craftPark(40000, bytes, settled: false);
      final part = partPathFor(TransferManager.styleOf(null), at('dst/big.bin'), id);
      final c2 = fresh();
      addTearDown(c2.dispose);
      final m2 = c2.read(transfersProvider.notifier)..ui = ui;
      final stranded = c2.read(transfersProvider).single;
      expect(stranded.state, TransferState.interrupted);
      m2.resume(stranded.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c2.read(transfersProvider).single.state, TransferState.interrupted, reason: 'not resumable');

      await m2.retry(stranded.id);
      for (var i = 0; i < 500 && c2.read(transfersProvider).single.state.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final done = c2.read(transfersProvider).single;
      expect(done.state, TransferState.completed);
      expect(File(at('dst/big.bin')).readAsBytesSync(), bytes);
      expect(File(part).existsSync(), isFalse, reason: 'the unsettled part was cleaned');
      await m2.saved;
    });

    test('cancelling a parked transfer cleans its part', () async {
      final bytes = List<int>.generate(5000, (i) => i & 0xff);
      File(at('src/small.bin')).writeAsBytesSync(bytes);
      final id = manager().enqueue(from: null, paths: [at('src/small.bin')], to: null, targetDir: at('dst')).single;
      manager().pause(id);
      final parked = await waitFor(id, TransferState.paused);
      expect(File(parked.checkpoint!.part).existsSync(), isTrue);
      await manager().cancel(id);
      final gone = await waitFor(id, TransferState.cancelled);
      expect(gone.checkpoint, isNull);
      expect(File(parked.checkpoint!.part).existsSync(), isFalse);
      expect(File(at('dst/small.bin')).existsSync(), isFalse);
    });

    test('a parked transfer holds its target until it is resolved', () async {
      final id1 = manager().enqueue(from: null, paths: [at('src/a.txt')], to: null, targetDir: at('dst')).single;
      manager().pause(id1);
      await waitFor(id1, TransferState.paused);
      final id2 = manager().enqueue(from: null, paths: [at('src/a.txt')], to: null, targetDir: at('dst')).single;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(manager().byId(id2)?.state, TransferState.queued);
      manager().resume(id1);
      await waitFor(id1, TransferState.completed);
      await waitFor(id2, TransferState.completed);
      expect(File(at('dst/a.txt')).readAsStringSync(), 'alpha');
    });

    test('pausing a directory transfer does nothing', () async {
      final id = manager().enqueue(from: null, paths: [at('src/sub')], to: null, targetDir: at('dst')).single;
      manager().pause(id);
      final done = await settle();
      expect(done.single.state, TransferState.completed);
      expect(done.single.checkpoint, isNull);
      expect(File(at('dst/sub/b.txt')).readAsStringSync(), 'bravo!');
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
