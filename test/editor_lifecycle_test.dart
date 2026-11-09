import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/adapters/local_fs.dart';
import 'package:sshairy/features/files/application/edits.dart';
import 'package:sshairy/features/files/application/file_systems.dart';
import 'package:sshairy/features/files/application/open_with.dart';
import 'package:sshairy/features/files/domain/open_with.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport;

class _Editor implements EditorLauncher {
  final exits = <Completer<EditorExit>>[];
  var observed = true;
  @override
  bool get canChoose => true;
  @override
  Future<List<OpenWithApp>> apps(String name) async => const [];
  @override
  Future<OpenWithApp?> program(String path) async => null;
  @override
  Future<EditorLaunch> launch(OpenWithApp app, String path) async {
    if (!observed) return const EditorLaunch.started();
    final exit = Completer<EditorExit>();
    exits.add(exit);
    return EditorLaunch.started(exited: exit.future);
  }
}

class _Pool extends FileSystems {
  _Pool(this.server, this.hostValue, ConnectionManager manager) : super(manager, (_) => hostValue);
  final Directory server;
  final Host hostValue;
  var offline = false;
  @override
  Host? host(HostId id) => hostValue;
  @override
  Future<FsHandle> acquire(HostId? id, ConnectPrompts prompts) async {
    if (offline) throw const FsError(FsFailure.lost);
    return FsHandle(const LocalFileSystem(), () {});
  }
}

void main() {
  late Directory data, remote;
  late ProviderContainer container;
  late _Editor editor;
  late _Pool pool;
  late ConnectionManager manager;
  const host = Host(id: HostId('h'), label: 'test', address: 'unused', username: 'u');

  ProviderContainer start() => ProviderContainer(
    overrides: [
      dataDirProvider.overrideWithValue(data.path),
      editorLauncherProvider.overrideWithValue(editor),
      fileSystemsProvider.overrideWithValue(pool),
    ],
  );

  setUp(() {
    data = Directory.systemTemp.createTempSync('sshairy-edit-life-data-');
    remote = Directory.systemTemp.createTempSync('sshairy-edit-life-server-');
    manager = ConnectionManager((_, _, _) async => FakeTransport());
    pool = _Pool(remote, host, manager);
    editor = _Editor();
    container = start();
  });
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await container.read(editsProvider.notifier).shutdown();
    await container.read(editsProvider.notifier).saved;
    container.dispose();
    manager.closeAll();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    data.deleteSync(recursive: true);
    remote.deleteSync(recursive: true);
  });

  Future<void> until(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('edit did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<(File, ExternalEdit)> open() async {
    final file = File('${remote.path}/notes.txt')..writeAsStringSync('original');
    // Match the whole-second modification times reported by SFTP.
    file.setLastModifiedSync(DateTime.utc(2026, 1, 1));
    await container.read(editsProvider.notifier).open(host, file.path);
    final edit = container.read(editsProvider).single;
    expect(edit.autoUpload, isTrue);
    return (file, edit);
  }

  test('final save uploads before a reliably closed editor ends the edit', () async {
    final (file, edit) = await open();
    await File(edit.localPath).writeAsString('last saved change');
    editor.exits.single.complete(EditorExit.closed);
    await until(() => container.read(editsProvider).isEmpty);
    expect(file.readAsStringSync(), 'last saved change');
    expect(File(edit.localPath).existsSync(), isFalse);
  });

  test('unchecked synchronization preserves a changed copy when the editor closes', () async {
    final (file, edit) = await open();
    container.read(editsProvider.notifier).setAutoUpload(edit.id, false);
    await File(edit.localPath).writeAsString('keep local');
    editor.exits.single.complete(EditorExit.closed);
    await until(() => container.read(editsProvider).single.state == EditState.modified);
    expect(file.readAsStringSync(), 'original');
    expect(File(edit.localPath).readAsStringSync(), 'keep local');
  });

  test('a conflict on final save keeps the edit and local copy', () async {
    final (file, edit) = await open();
    await file.writeAsString('someone else saved on server');
    await File(edit.localPath).writeAsString('my last save');
    editor.exits.single.complete(EditorExit.closed);
    await until(() => container.read(editsProvider).single.state == EditState.conflict);
    expect(file.readAsStringSync(), 'someone else saved on server');
    expect(File(edit.localPath).readAsStringSync(), 'my last save');
  });

  test('a final save that cannot upload keeps the draft and can be retried after reconnecting', () async {
    final (file, edit) = await open();
    pool.offline = true;
    await File(edit.localPath).writeAsString('saved before the connection failed');
    editor.exits.single.complete(EditorExit.closed);
    await until(() => container.read(editsProvider).single.state == EditState.failed);
    expect(container.read(editsProvider).single.error, FsFailure.lost.name);
    expect(file.readAsStringSync(), 'original');
    expect(File(edit.localPath).readAsStringSync(), 'saved before the connection failed');

    pool.offline = false;
    await container.read(editsProvider.notifier).upload(edit.id);
    await until(() => container.read(editsProvider).single.state == EditState.clean);
    expect(file.readAsStringSync(), 'saved before the connection failed');
    await container.read(editsProvider.notifier).finish(edit.id);
    expect(container.read(editsProvider), isEmpty);
    expect(File(edit.localPath).existsSync(), isFalse);
  });

  test('shutdown notices the last save before debounce and a restart keeps it for uploading', () async {
    final (file, edit) = await open();
    await File(edit.localPath).writeAsString('last save immediately before quitting');
    await container.read(editsProvider.notifier).shutdown();
    expect(container.read(editsProvider).single.state, EditState.modified);
    expect(file.readAsStringSync(), 'original');
    expect(File(edit.localPath).readAsStringSync(), 'last save immediately before quitting');

    container.dispose();
    container = start();
    final restored = container.read(editsProvider).single;
    expect(restored.id, edit.id);
    expect(restored.unsaved, isTrue);
    expect(File(restored.localPath).readAsStringSync(), 'last save immediately before quitting');
    await container.read(editsProvider.notifier).upload(restored.id);
    expect(container.read(editsProvider).single.state, EditState.clean);
    expect(file.readAsStringSync(), 'last save immediately before quitting');
    expect(File(restored.localPath).existsSync(), isTrue, reason: 'recovered edits stay until explicitly ended');
  });

  test('a persisted draft recovers after disposal without shutdown', () async {
    final (file, edit) = await open();
    final edits = container.read(editsProvider.notifier);
    edits.setAutoUpload(edit.id, false);
    await edits.saved;
    await File(edit.localPath).writeAsString('saved draft before service disposal');
    await until(() => container.read(editsProvider).single.state == EditState.modified);
    await edits.saved;

    container.dispose();
    container = start();
    final restored = container.read(editsProvider).single;
    expect(restored.id, edit.id);
    expect(restored.state, EditState.modified);
    expect(restored.unsaved, isTrue);
    expect(File(restored.localPath).readAsStringSync(), 'saved draft before service disposal');
    expect(file.readAsStringSync(), 'original');

    await container.read(editsProvider.notifier).upload(restored.id);
    expect(container.read(editsProvider).single.state, EditState.clean);
    expect(file.readAsStringSync(), 'saved draft before service disposal');
  });

  test('reopening while the previous editor closes keeps the copy until both documents close', () async {
    final (_, edit) = await open();
    editor.exits.first.complete(EditorExit.closed);
    expect(await container.read(editsProvider.notifier).reopen(edit.id), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(editsProvider), hasLength(1));
    expect(File(edit.localPath).existsSync(), isTrue);
    editor.exits.last.complete(EditorExit.closed);
    await until(() => container.read(editsProvider).isEmpty);
  });

  test('handed off or unobserved editors never end the record on process exit', () async {
    final (_, edit) = await open();
    editor.exits.single.complete(EditorExit.handedOff);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(editsProvider), hasLength(1));
    expect(File(edit.localPath).existsSync(), isTrue);
    editor.observed = false;
    expect(await container.read(editsProvider.notifier).reopen(edit.id), isTrue);
    expect(container.read(editsProvider), hasLength(1));
  });
}
