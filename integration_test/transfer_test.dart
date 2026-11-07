// Real server only (docs/TESTING.md §2). Files live under ~/sshairy-test/xfer-<id> on the server and in a temp
// directory here; both are removed afterwards and the test fails if the server directory is still there.
// The link to the test server is slow (about 3 Mbit/s down, 5 Mbit/s up, 160 ms round trip), so the sizes are
// chosen to show hashes, pause/resume, cancel and bounded memory rather than to move gigabytes: a transfer that
// buffered its source would be at the full 256 MiB within seconds, so a few tens of MiB moved is enough to tell.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/features/files/application/browser.dart';
import 'package:sshairy/features/files/domain/transfer.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';

import 'support/server.dart';

const _mib = 1 << 20;

// ignore: avoid_print
void report(String line) => print('REPORT $line');

/// Answers a conflict the same way every time and remembers what it was asked.
class _Ui implements TransferUi {
  _Ui(this.prompts);

  @override
  final ConnectPrompts prompts;
  ConflictChoice choice = ConflictChoice.cancel;
  final asked = <Conflict>[];

  @override
  Future<ConflictAnswer?> conflict(Transfer transfer, Conflict conflict, CancellationToken cancel) async {
    asked.add(conflict);
    return ConflictAnswer(choice);
  }
}

/// Event-loop lag and the process's resident memory, sampled while something heavy runs.
class _Sampler {
  final _clock = Stopwatch()..start();
  late final Timer _timer;
  var _last = 0, _ticks = 0;
  var maxLag = 0, peakRss = ProcessInfo.currentRss;
  final baselineRss = ProcessInfo.currentRss;

  void start() {
    _last = _clock.elapsedMilliseconds;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = _clock.elapsedMilliseconds;
      maxLag = max(maxLag, now - _last - 50);
      _last = now;
      if (++_ticks % 10 == 0) peakRss = max(peakRss, ProcessInfo.currentRss);
    });
  }

  void stop() {
    _timer.cancel();
    peakRss = max(peakRss, ProcessInfo.currentRss);
  }

  int get grewMiB => (peakRss - baselineRss) ~/ _mib;
}

class _Env {
  _Env(this.server, this.dir, this.container, this.host, this.root, this.home);

  final TestServer server;
  final Directory dir;
  final ProviderContainer container;
  final HostId host;
  final String root, home;
  late final prompts = ScriptedPrompts(server);

  TransferManager get transfers => container.read(transfersProvider.notifier);
  Host get hostRecord => container.read(hostsProvider.notifier).byId(host)!;

  Future<String> remote(String script) => container.exec(hostRecord, prompts, script);

  /// A path inside this test's local work directory.
  String local(String name) => '${dir.path}${Platform.pathSeparator}work${Platform.pathSeparator}$name';

  Future<String> localHash(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

  Future<String> serverHash(String path) async => (await remote("sha256sum '$path' | cut -d' ' -f1")).trim();

  Future<TransferId> upload(String path, String to) => _one(from: null, paths: [path], to: hostRecord, target: to);

  Future<TransferId> download(String path, String to) => _one(from: hostRecord, paths: [path], to: null, target: to);

  Future<TransferId> _one({Host? from, required List<String> paths, Host? to, required String target}) async {
    final ids = transfers.enqueue(from: from, paths: paths, to: to, targetDir: target);
    expect(ids, hasLength(1));
    return ids.single;
  }

  Future<Transfer> until(
    TransferId id,
    bool Function(Transfer t) test, {
    Duration limit = const Duration(minutes: 5),
  }) async {
    final end = DateTime.now().add(limit);
    while (true) {
      final t = transfers.byId(id)!;
      if (test(t)) return t;
      if (DateTime.now().isAfter(end)) {
        fail('timed out: ${t.state} ${t.bytes}/${t.total} error=${t.error} ${t.detail}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<Transfer> finished(TransferId id, {Duration limit = const Duration(minutes: 5)}) =>
      until(id, (t) => !t.state.active, limit: limit);

  Future<Transfer> completed(TransferId id, {Duration limit = const Duration(minutes: 5)}) async {
    final t = await finished(id, limit: limit);
    expect(t.state, TransferState.completed, reason: '${t.error} ${t.detail}');
    return t;
  }

  Future<int> latency() async {
    final clock = Stopwatch()..start();
    await remote('true');
    return clock.elapsedMilliseconds;
  }
}

Future<void> _withEnv(Future<void> Function(_Env e) body) async {
  final server = TestServer.fromEnvironment();
  final dir = await Directory.systemTemp.createTemp('sshairy-xfer-');
  await Directory('${dir.path}${Platform.pathSeparator}work').create();
  final container = appContainer(dir);
  final host = server.host('xfer-host', const AuthPolicy(allowInteractive: false));
  await container.read(hostsProvider.notifier).save(host);
  final id = 'xfer-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
  final prompts = ScriptedPrompts(server);
  final home = (await container.exec(
    container.read(hostsProvider.notifier).byId(host.id)!,
    prompts,
    'echo \$HOME',
  )).trim();
  final env = _Env(server, dir, container, host.id, '$home/sshairy-test/$id', home);
  final ui = _Ui(prompts);
  env.transfers.ui = ui;
  var made = false;
  try {
    made = true;
    await env.remote("mkdir -p '${env.root}'");
    await body(env);
  } finally {
    for (final t in container.read(transfersProvider)) {
      if (!t.state.active) continue;
      try {
        await env.transfers.cancel(t.id).timeout(const Duration(seconds: 30));
      } on Object {
        // The part is removed with the directory below.
      }
    }
    var cleaned = 'skipped';
    if (made) {
      try {
        cleaned = await env.remote(
          "rm -rf '${env.root}'; rmdir ~/sshairy-test 2>/dev/null; [ -e '${env.root}' ] && echo left || echo gone",
        );
      } on Object catch (e) {
        cleaned = 'cleanup failed: $e';
      }
    }
    container.dispose();
    await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
    expect(cleaned.trim(), 'gone', reason: 'the server directory must be removed');
  }
}

Uint8List _randomBlock(Random random, int size) => Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));

Future<void> _writeBig(String path, int mib) async {
  final block = _randomBlock(Random(11), _mib);
  final file = await File(path).open(mode: FileMode.write);
  for (var i = 0; i < mib; i++) {
    await file.writeFrom(block);
  }
  await file.close();
}

Future<Map<String, String>> _localTree(String root) async {
  final out = <String, String>{};
  await for (final e in Directory(root).list(recursive: true)) {
    if (e is! File) continue;
    final rel = e.path.substring(root.length + 1).replaceAll(r'\', '/');
    out[rel] = sha256.convert(await e.readAsBytes()).toString();
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('transfers: files and a folder round trip with equal hashes, conflicts do what was chosen', (
    tester,
  ) async {
    await _withEnv((e) async {
      final random = Random(5);
      final ui = e.transfers.ui! as _Ui;

      final a = e.local('a.bin');
      await File(a).writeAsBytes(_randomBlock(random, 3 * _mib));
      final aHash = await e.localHash(a);
      final up = await e.upload(a, e.root);
      final done = await e.completed(up);
      expect(done.bytes, 3 * _mib);
      expect(await e.serverHash('${e.root}/a.bin'), aHash, reason: 'uploaded bytes');
      expect((await e.remote("ls -A '${e.root}'")).trim(), 'a.bin', reason: 'no part is left beside the target');

      await Directory(e.local('down')).create();
      await e.completed(await e.download('${e.root}/a.bin', e.local('down')));
      expect(await e.localHash(e.local('down${Platform.pathSeparator}a.bin')), aHash, reason: 'downloaded bytes');

      // Conflicts: skip keeps the server's file, replace swaps it, keep both adds a second one, cancel ends it.
      await File(a).writeAsBytes(_randomBlock(random, 2 * _mib));
      final aNew = await e.localHash(a);
      ui.choice = ConflictChoice.skip;
      final skipped = await e.finished(await e.upload(a, e.root));
      expect(skipped.state, TransferState.completed);
      expect(skipped.skipped, 1);
      expect(await e.serverHash('${e.root}/a.bin'), aHash, reason: 'skip leaves the old file');
      ui.choice = ConflictChoice.cancel;
      final cancelled = await e.finished(await e.upload(a, e.root));
      expect(cancelled.state, TransferState.cancelled);
      expect(await e.serverHash('${e.root}/a.bin'), aHash, reason: 'cancel leaves the old file');
      ui.choice = ConflictChoice.keepBoth;
      await e.completed(await e.upload(a, e.root));
      expect(await e.serverHash('${e.root}/a (1).bin'), aNew, reason: 'keep both writes the new name');
      expect(await e.serverHash('${e.root}/a.bin'), aHash);
      ui.choice = ConflictChoice.replace;
      await e.completed(await e.upload(a, e.root));
      expect(await e.serverHash('${e.root}/a.bin'), aNew, reason: 'replace swaps the file');
      expect(ui.asked.map((c) => c.kind).toSet(), {ConflictKind.file});
      expect((await e.remote("ls -A '${e.root}' | wc -l")).trim(), '2', reason: 'only a.bin and a (1).bin remain');

      // A folder: nested, spaces, Chinese names, an empty file and a one-byte file.
      final tree = e.local('tree');
      final files = <String, List<int>>{
        'empty.txt': <int>[],
        'one.bin': [7],
        '中文 名字.txt': 'こんにちは 你好'.codeUnits,
        'sub dir/inner file.bin': _randomBlock(random, 70000),
        'sub dir/deeper/x.bin': _randomBlock(random, 5),
        for (var i = 0; i < 30; i++) 'many/f$i.bin': _randomBlock(random, 1000 + i),
      };
      for (final entry in files.entries) {
        final file = File('$tree${Platform.pathSeparator}${entry.key.replaceAll('/', Platform.pathSeparator)}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value);
      }
      final expected = await _localTree(tree);
      expect(expected, hasLength(files.length));

      final clock = Stopwatch()..start();
      final folder = await e.completed(await e.upload(tree, e.root));
      report('folder upload: ${folder.files} files in ${clock.elapsedMilliseconds} ms');
      expect(folder.files, files.length);
      final listing = await e.remote("cd '${e.root}/tree' && find . -type f -print0 | xargs -0 sha256sum");
      final remoteTree = {
        for (final line in listing.trim().split('\n')) line.substring(66).replaceFirst('./', ''): line.substring(0, 64),
      };
      expect(remoteTree, expected, reason: 'every uploaded file matches');
      expect((await e.remote("find '${e.root}' -name '*.part' | wc -l")).trim(), '0');

      await e.completed(await e.download('${e.root}/tree', e.local('down')));
      expect(await _localTree(e.local('down${Platform.pathSeparator}tree')), expected, reason: 'every downloaded file');
    });
  });

  testWidgets('transfers: pause and resume keep the hash, a changed source is refused', (tester) async {
    await _withEnv((e) async {
      final random = Random(9);

      // Upload paused part-way, with the part on the server the size the checkpoint says.
      final up = e.local('up.bin');
      await File(up).writeAsBytes(_randomBlock(random, 12 * _mib));
      final upHash = await e.localHash(up);
      var id = await e.upload(up, e.root);
      await e.until(id, (t) => t.bytes > 3 * _mib);
      e.transfers.pause(id);
      var t = await e.until(id, (t) => t.state == TransferState.paused || !t.state.active);
      expect(t.state, TransferState.paused, reason: '${t.error} ${t.detail}');
      final checkpoint = t.checkpoint!;
      expect(checkpoint.settled, isTrue);
      expect(checkpoint.offset, greaterThan(0));
      expect(checkpoint.offset, lessThan(12 * _mib));
      expect((await e.remote("stat -c %s '${checkpoint.part}'")).trim(), '${checkpoint.offset}', reason: 'part size');
      expect((await e.remote("ls -A '${e.root}'")).trim(), checkpoint.part.split('/').last, reason: 'only the part');
      report('upload paused at ${checkpoint.offset} of ${12 * _mib}');
      e.transfers.resume(id);
      await e.completed(id);
      expect(await e.serverHash('${e.root}/up.bin'), upHash, reason: 'resumed upload');
      expect((await e.remote("ls -A '${e.root}'")).trim(), 'up.bin');

      // Download paused part-way.
      await e.remote("head -c ${10 * _mib} /dev/urandom > '${e.root}/down.bin'");
      final downHash = await e.serverHash('${e.root}/down.bin');
      await Directory(e.local('dl')).create();
      id = await e.download('${e.root}/down.bin', e.local('dl'));
      await e.until(id, (t) => t.bytes > 2 * _mib);
      e.transfers.pause(id);
      t = await e.until(id, (t) => t.state == TransferState.paused || !t.state.active);
      expect(t.state, TransferState.paused, reason: '${t.error} ${t.detail}');
      report('download paused at ${t.checkpoint!.offset} of ${10 * _mib}');
      expect(File(t.checkpoint!.part).lengthSync(), t.checkpoint!.offset, reason: 'local part size');
      e.transfers.resume(id);
      await e.completed(id);
      expect(await e.localHash(e.local('dl${Platform.pathSeparator}down.bin')), downHash, reason: 'resumed download');

      // The source changes while paused: resuming is refused and removing the transfer cleans the part.
      final changing = e.local('changing.bin');
      await File(changing).writeAsBytes(_randomBlock(random, 10 * _mib));
      id = await e.upload(changing, e.root);
      await e.until(id, (t) => t.bytes > 2 * _mib);
      e.transfers.pause(id);
      t = await e.until(id, (t) => t.state == TransferState.paused || !t.state.active);
      expect(t.state, TransferState.paused, reason: '${t.error} ${t.detail}');
      await File(changing).writeAsBytes([1], mode: FileMode.append);
      e.transfers.resume(id);
      t = await e.finished(id);
      expect(t.state, TransferState.failed);
      expect(t.error, 'sourceChanged');
      expect(await e.remote("[ -e '${e.root}/changing.bin' ] && echo target || echo none"), 'none\n');
      await e.transfers.remove(id);
      expect(e.transfers.byId(id), isNull);
      expect(
        (await e.remote("ls -A '${e.root}' | grep -c part || true")).trim(),
        '0',
        reason: 'removing the transfer removes its part',
      );
    });
  });

  testWidgets('transfers: a quit while one file runs parks it, and a restart resumes it', (tester) async {
    await _withEnv((e) async {
      final src = e.local('quit.bin');
      await File(src).writeAsBytes(_randomBlock(Random(3), 10 * _mib));
      final hash = await e.localHash(src);
      final id = await e.upload(src, e.root);
      await e.until(id, (t) => t.bytes > 2 * _mib);
      await e.transfers.shutdown(grace: const Duration(seconds: 20));
      await e.transfers.saved;
      final parked = e.transfers.byId(id)!;
      report('after shutdown: ${parked.state} offset=${parked.checkpoint?.offset}');
      expect(parked.state, anyOf(TransferState.paused, TransferState.interrupted));

      // A new process: the same data directory, nothing in memory.
      final again = appContainer(e.dir);
      final restored = again.read(transfersProvider).where((t) => t.id == id).single;
      expect(restored.state, anyOf(TransferState.paused, TransferState.interrupted), reason: 'restored from disk');
      expect(restored.checkpoint?.settled, isTrue);
      final manager = again.read(transfersProvider.notifier)..ui = _Ui(ScriptedPrompts(e.server));
      manager.resume(id);
      final end = DateTime.now().add(const Duration(minutes: 3));
      while (manager.byId(id)!.state.active && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final last = manager.byId(id)!;
      expect(last.state, TransferState.completed, reason: '${last.error} ${last.detail}');
      final prompts = ScriptedPrompts(e.server);
      final check = await again.exec(
        again.read(hostsProvider.notifier).byId(e.host)!,
        prompts,
        "sha256sum '${e.root}/quit.bin'",
      );
      expect(check.substring(0, 64), hash, reason: 'resumed after restart');
      again.dispose();
    });
  });

  testWidgets(
    'transfers: a 256 MiB upload and a 10 GiB sparse download stay bounded, cancel clean, and leave the link usable',
    (tester) async {
      await _withEnv((e) async {
        final big = e.local('big.bin');
        await _writeBig(big, 256);
        await e.remote("truncate -s 10G '${e.root}/sparse.bin'");
        expect(
          (await e.remote("du -k '${e.root}/sparse.bin' | cut -f1")).trim(),
          '0',
          reason: 'the source holds no disk',
        );

        final idle = [for (var i = 0; i < 3; i++) await e.latency()];
        report('exec round trip while idle: $idle ms');

        Future<void> watch(String label, TransferId id, {Duration length = const Duration(seconds: 30)}) async {
          final sampler = _Sampler()..start();
          final during = <int>[];
          final clock = Stopwatch()..start();
          var next = const Duration(seconds: 6);
          while (clock.elapsed < length) {
            final t = e.transfers.byId(id)!;
            expect(t.state.active, isTrue, reason: '$label ended early: ${t.state} ${t.error} ${t.detail}');
            if (clock.elapsed > next) {
              during.add(await e.latency());
              next += const Duration(seconds: 8);
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          final before = e.transfers.byId(id)!;
          await e.transfers.cancel(id);
          final after = await e.finished(id);
          sampler.stop();
          report(
            '$label: ${before.bytes ~/ _mib} MiB in ${clock.elapsed.inSeconds} s, rss +${sampler.grewMiB} MiB '
            '(peak ${sampler.peakRss ~/ _mib}), max loop lag ${sampler.maxLag} ms, exec round trip during $during ms',
          );
          expect(after.state, TransferState.cancelled, reason: '$label: ${after.error} ${after.detail}');
          expect(after.checkpoint, isNull, reason: '$label: no part is kept');
          expect(sampler.grewMiB, lessThan(150), reason: '$label: memory must stay bounded');
          expect(sampler.maxLag, lessThan(1000), reason: '$label: the event loop must not stall');
          expect(await e.latency(), lessThan(5000), reason: '$label: the connection is still usable after cancel');
        }

        await watch('upload 256 MiB', await e.upload(big, e.root));
        expect((await e.remote("ls -A '${e.root}'")).trim(), 'sparse.bin', reason: 'a cancelled upload leaves nothing');

        await Directory(e.local('dl')).create();
        await watch('download 10 GiB sparse', await e.download('${e.root}/sparse.bin', e.local('dl')));
        expect(await Directory(e.local('dl')).list().isEmpty, isTrue, reason: 'a cancelled download leaves nothing');
      });
    },
  );

  testWidgets('transfers: a folder of 10,000 entries lists and sorts quickly', (tester) async {
    await _withEnv((e) async {
      await e.remote("mkdir '${e.root}/many' && cd '${e.root}/many' && seq -f 'file-%05g.txt' 1 10000 | xargs touch");
      expect((await e.remote("ls -A '${e.root}/many' | wc -l")).trim(), '10000');
      final browser = FileBrowser(e.container.read(connectionManagerProvider));
      final sampler = _Sampler()..start();
      final clock = Stopwatch()..start();
      await browser.open(e.hostRecord, e.prompts, at: '${e.root}/many');
      final listed = clock.elapsedMilliseconds;
      expect(browser.entries, hasLength(10000));
      clock.reset();
      final visible = browser.visible;
      final sorted = clock.elapsedMilliseconds;
      sampler.stop();
      report(
        '10,000 entries: listed in $listed ms, filtered and sorted in $sorted ms, rss +${sampler.grewMiB} MiB, max lag ${sampler.maxLag} ms',
      );
      expect(visible, hasLength(10000));
      expect(visible.first.name, 'file-00001.txt');
      expect(sorted, lessThan(1000));
      browser.dispose();
    });
  });
}
