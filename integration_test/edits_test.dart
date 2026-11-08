// Real server only (docs/TESTING.md §2). Files live under ~/sshairy-test/edit-<id> on the server; the directory is
// removed afterwards and the test fails if it is still there. The program that would open the copy is replaced by a
// recorder and an "editor" is played by this test (an atomic replace, an in-place write, a burst of saves), so
// what is checked is the app's side: download, watching, upload, conflicts, quitting and recovery. Whether a
// particular editor saves in a way the watcher sees still needs the author's own editor (F-05).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/features/files/application/edits.dart';
import 'package:sshairy/features/files/domain/transfer.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';

import 'support/server.dart';

// ignore: avoid_print
void report(String line) => print('REPORT $line');

/// Only supplies the prompts the edit flow dials with; edits never ask about conflicts through it.
class _Ui implements TransferUi {
  _Ui(this.prompts);

  @override
  final ConnectPrompts prompts;

  @override
  Future<ConflictAnswer?> conflict(Transfer transfer, Conflict conflict, CancellationToken cancel) async => null;
}

/// Stands in for the programs the machine would start: it records the file and starts nothing.
class _Editor implements EditorLauncher {
  _Editor(this.env);

  final _Env env;

  @override
  bool get canChoose => false;

  @override
  Future<List<OpenWithApp>> apps(String fileName) async => const [];

  @override
  Future<OpenWithApp?> program(String executable) async => null;

  @override
  Future<EditorLaunch> launch(OpenWithApp app, String path) async {
    env.opened.add(path);
    if (!env.watch) return const EditorLaunch.started();
    final exit = Completer<EditorExit>();
    env.exits.add(exit);
    return EditorLaunch.started(exited: exit.future);
  }
}

class _Env {
  _Env(this.server, this.dir, this.hostId, this.root);

  final TestServer server;
  final Directory dir;
  final HostId hostId;
  final String root;
  final opened = <String>[];

  /// With [watch] set, each launch can be ended by completing the matching entry, as a closing editor would.
  final exits = <Completer<EditorExit>>[];
  var watch = false;
  late ProviderContainer container = start();

  ProviderContainer start() {
    final c = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        ...appOverrides(),
        editorLauncherProvider.overrideWithValue(_Editor(this)),
      ],
    );
    c.read(transfersProvider.notifier).ui = _Ui(prompts);
    return c;
  }

  /// The app quit and started again over the same data directory.
  void restart() {
    container.dispose();
    container = start();
  }

  late final prompts = ScriptedPrompts(server);

  ExternalEdits get edits => container.read(editsProvider.notifier);
  Host get host => container.read(hostsProvider.notifier).byId(hostId)!;
  ExternalEdit edit(String name) => container.read(editsProvider).firstWhere((e) => e.name == name);

  Future<String> remote(String script) => container.exec(host, prompts, script);

  Future<String> cat(String name) => remote("cat '$root/$name'");

  Future<void> until(String what, FutureOr<bool> Function() done, {int seconds = 30}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!await done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> untilRemote(String name, String content) =>
      until('$name to hold ${content.trim()}', () async => await cat(name) == content);

  Future<void> untilState(String name, EditState state) => until('$name to be $state', () => edit(name).state == state);

  /// What editors that never touch the file itself do: write a neighbour, then move it over the original.
  Future<void> atomicSave(ExternalEdit e, String content) async {
    final neighbour = File('${e.localPath}.tmp~');
    await neighbour.writeAsString(content);
    await neighbour.rename(e.localPath);
  }

  Future<void> inPlaceSave(ExternalEdit e, String content) => File(e.localPath).writeAsString(content);
}

Future<void> _withEnv(Future<void> Function(_Env e) body) async {
  final server = TestServer.fromEnvironment();
  final dir = await Directory.systemTemp.createTemp('sshairy-edit-');
  final host = server.host('edit-host', const AuthPolicy(allowInteractive: false));
  final id = 'edit-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
  final probe = appContainer(dir);
  await probe.read(hostsProvider.notifier).save(host);
  final home = (await probe.exec(
    probe.read(hostsProvider.notifier).byId(host.id)!,
    ScriptedPrompts(server),
    'echo \$HOME',
  )).trim();
  probe.dispose();
  final env = _Env(server, dir, host.id, '$home/sshairy-test/$id');
  var made = false;
  try {
    made = true;
    await env.remote("mkdir -p '${env.root}'");
    await body(env);
  } finally {
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
    env.container.dispose();
    await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
    expect(cleaned.trim(), 'gone', reason: 'the server directory must be removed');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edits: saves reach the server, a changed remote is a conflict, the user picks what wins', (
    tester,
  ) async {
    await _withEnv((e) async {
      await e.remote("printf 'v1 remote\\n' > '${e.root}/note.txt'");
      final opened = await e.edits.open(e.host, '${e.root}/note.txt');
      expect(opened, isA<Ok<void>>(), reason: '$opened');

      var edit = e.edit('note.txt');
      expect(edit.state, EditState.clean);
      expect(await File(edit.localPath).readAsString(), 'v1 remote\n');
      expect(edit.localPath, startsWith(e.dir.path), reason: 'the copy lives in the private data directory');
      expect(e.opened, [edit.localPath]);
      expect(edit.baseline.size, 10);
      expect(edit.autoUpload, isTrue, reason: 'saves are synchronised unless the user turns it off');

      // An atomic replace is noticed although the watched file itself disappears for a moment.
      e.edits.setAutoUpload(edit.id, false);
      await e.atomicSave(edit, 'v2 atomic\n');
      await e.untilState('note.txt', EditState.modified);
      expect(await e.cat('note.txt'), 'v1 remote\n', reason: 'nothing is uploaded unless asked');
      await e.edits.upload(edit.id);
      expect(e.edit('note.txt').state, EditState.clean);
      expect(await e.cat('note.txt'), 'v2 atomic\n');
      expect(e.edit('note.txt').baseline.size, 10);

      // With automatic upload an in-place write goes by itself.
      e.edits.setAutoUpload(edit.id, true);
      await e.inPlaceSave(edit, 'v3 in place, a little longer\n');
      await e.untilRemote('note.txt', 'v3 in place, a little longer\n');
      await e.untilState('note.txt', EditState.clean);

      // A burst of saves ends with the last one on the server; an older upload never gets the last word.
      for (var i = 1; i <= 8; i++) {
        await e.inPlaceSave(edit, 'burst $i ${'x' * i}\n');
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await e.untilRemote('note.txt', 'burst 8 xxxxxxxx\n');
      await e.untilState('note.txt', EditState.clean);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(await e.cat('note.txt'), 'burst 8 xxxxxxxx\n', reason: 'no late upload of an older save');
      expect(await File(edit.localPath).readAsString(), 'burst 8 xxxxxxxx\n');
      e.edits.setAutoUpload(edit.id, false);

      // The server's file changed under us: the upload stops, the draft stays, and the user decides.
      await e.remote("printf 'changed on the server\\n' > '${e.root}/note.txt'");
      await e.inPlaceSave(edit, 'my edit\n');
      await e.untilState('note.txt', EditState.modified);
      await e.edits.upload(edit.id);
      expect(e.edit('note.txt').state, EditState.conflict);
      expect(await e.cat('note.txt'), 'changed on the server\n', reason: 'a conflict overwrites nothing');
      expect(await File(edit.localPath).readAsString(), 'my edit\n', reason: 'and keeps the local draft');

      await e.edits.redownload(edit.id);
      expect(e.edit('note.txt').state, EditState.clean);
      expect(await File(edit.localPath).readAsString(), 'changed on the server\n');

      await e.inPlaceSave(edit, 'second edit\n');
      await e.untilState('note.txt', EditState.modified);
      await e.remote("printf 'changed twice\\n' > '${e.root}/note.txt'");
      await e.edits.upload(edit.id);
      expect(e.edit('note.txt').state, EditState.conflict);
      await e.edits.upload(edit.id, force: true);
      expect(e.edit('note.txt').state, EditState.clean);
      expect(await e.cat('note.txt'), 'second edit\n', reason: 'overwriting was the user\'s choice');

      await e.inPlaceSave(edit, 'third edit\n');
      await e.untilState('note.txt', EditState.modified);
      await e.remote("printf 'third server change\\n' > '${e.root}/note.txt'");
      await e.edits.upload(edit.id);
      expect(e.edit('note.txt').state, EditState.conflict);
      await e.edits.upload(edit.id, asCopy: true);
      final copy = e.container.read(editsProvider).firstWhere((x) => x.id == edit.id);
      expect(copy.state, EditState.clean);
      expect(copy.remotePath, isNot('${e.root}/note.txt'), reason: 'the edit now follows the copy');
      expect(await e.cat('note.txt'), 'third server change\n', reason: 'the original is untouched');
      expect(await e.remote("cat '${copy.remotePath}'"), 'third edit\n');
      final names = (await e.remote("ls '${e.root}'")).trim().split('\n');
      report('conflict copy was named ${names.where((n) => n != 'note.txt').join(', ')}');

      // A name Windows refuses is stored under a safe one and still goes back to the right place.
      await e.remote("printf 'odd\\n' > '${e.root}/a b:c 中文.txt'");
      expect(await e.edits.open(e.host, '${e.root}/a b:c 中文.txt'), isA<Ok<void>>());
      final odd = e.edit('a b:c 中文.txt');
      e.edits.setAutoUpload(odd.id, false);
      expect(File(odd.localPath).uri.pathSegments.last, 'a b_c 中文.txt');
      await e.inPlaceSave(odd, 'odd, saved\n');
      await e.untilState('a b:c 中文.txt', EditState.modified);
      await e.edits.upload(odd.id);
      expect(await e.cat('a b:c 中文.txt'), 'odd, saved\n');

      // Opening the same file again reopens the copy instead of downloading over the draft.
      await e.inPlaceSave(odd, 'draft kept\n');
      expect(await e.edits.open(e.host, '${e.root}/a b:c 中文.txt'), isA<Ok<void>>());
      expect(await File(odd.localPath).readAsString(), 'draft kept\n');
      expect(e.opened.where((p) => p == odd.localPath), hasLength(2));

      for (final left in [...e.container.read(editsProvider)]) {
        await e.edits.finish(left.id);
      }
      expect(e.container.read(editsProvider), isEmpty);
      expect(Directory('${e.dir.path}${Platform.pathSeparator}edits').listSync(), isEmpty, reason: 'no copy is left');
    });
  });

  testWidgets('edits: quitting keeps an unsaved copy and the next start can still upload it', (tester) async {
    await _withEnv((e) async {
      await e.remote("printf 'base\\n' > '${e.root}/keep.txt'");
      expect(await e.edits.open(e.host, '${e.root}/keep.txt'), isA<Ok<void>>());
      final edit = e.edit('keep.txt');

      // Saved just before quitting, before the watcher's delay has run out; quitting starts no upload even when
      // saves are synchronised.
      await e.inPlaceSave(edit, 'saved while quitting\n');
      await e.edits.shutdown();
      expect(e.edit('keep.txt').state, EditState.modified, reason: 'the late save is still noticed');
      expect(await e.cat('keep.txt'), 'base\n', reason: 'quitting uploads nothing by itself');

      e.restart();
      final back = e.edit('keep.txt');
      expect(back.unsaved, isTrue);
      expect(await File(back.localPath).readAsString(), 'saved while quitting\n');
      await e.edits.upload(back.id);
      expect(e.edit('keep.txt').state, EditState.clean);
      expect(await e.cat('keep.txt'), 'saved while quitting\n');

      // The recovered copy is watched again.
      e.edits.setAutoUpload(back.id, false);
      await e.inPlaceSave(back, 'after the restart\n');
      await e.untilState('keep.txt', EditState.modified);
      await e.edits.finish(back.id);
      expect(e.container.read(editsProvider), isEmpty);
    });
  });

  testWidgets('edits: closing the editor ends the edit only when nothing is left unsent', (tester) async {
    await _withEnv((e) async {
      e.watch = true;
      await e.remote("printf 'one\\n' > '${e.root}/sync.txt'; printf 'one\\n' > '${e.root}/off.txt'");

      // The last save is taken and uploaded before the edit ends, and the local copy goes with it.
      expect(await e.edits.open(e.host, '${e.root}/sync.txt'), isA<Ok<void>>());
      final sync = e.edit('sync.txt');
      expect(sync.autoUpload, isTrue);
      expect(e.exits, hasLength(1));
      await e.inPlaceSave(sync, 'two, saved on exit\n');
      e.exits.last.complete(EditorExit.closed);
      await e.until('the edit to end', () => e.container.read(editsProvider).isEmpty);
      expect(await e.cat('sync.txt'), 'two, saved on exit\n');
      expect(Directory('${e.dir.path}${Platform.pathSeparator}edits').listSync(), isEmpty);

      // A program that passed the file to a running copy says nothing about the document: the edit stays.
      expect(await e.edits.open(e.host, '${e.root}/sync.txt'), isA<Ok<void>>());
      e.exits.last.complete(EditorExit.handedOff);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(e.edit('sync.txt').state, EditState.clean);
      await e.edits.finish(e.edit('sync.txt').id);

      // With synchronising off, a save that was never sent keeps the edit after the editor closed.
      expect(await e.edits.open(e.host, '${e.root}/off.txt'), isA<Ok<void>>());
      final off = e.edit('off.txt');
      e.edits.setAutoUpload(off.id, false);
      await e.inPlaceSave(off, 'kept local\n');
      await e.untilState('off.txt', EditState.modified);
      e.exits.last.complete(EditorExit.closed);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(e.edit('off.txt').state, EditState.modified);
      expect(await e.cat('off.txt'), 'one\n');

      for (final left in [...e.container.read(editsProvider)]) {
        await e.edits.finish(left.id);
      }
      expect(e.container.read(editsProvider), isEmpty);
    });
  });
}
