import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/application/browser.dart';
import 'package:sshairy/features/files/presentation/directory_tree.dart';
import 'package:sshairy/features/files/presentation/file_pane.dart';
import 'package:sshairy/features/files/presentation/files_page.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

class _ObservedValue<T> extends ValueNotifier<T> {
  _ObservedValue(super.value);
  bool get observed => hasListeners;
}

class _Files implements FileSystem {
  _Files(this.folders);
  final Map<String, List<String>> folders;
  final listed = <String>[];
  var closed = false;
  String? slowPath;
  Completer<List<FileEntry>>? listing;
  Completer<void>? mutation;

  @override
  PathStyle get style => PathStyle.posix;
  @override
  bool get canReplace => false;
  @override
  bool get canChmod => false;
  @override
  Future<String> home() async => '/';
  @override
  Future<String> resolve(String path) async => path;
  @override
  Future<List<FileEntry>> list(String path) async {
    listed.add(path);
    if (path == slowPath && listing != null) return listing!.future;
    return [
      for (final name in folders[path] ?? const <String>[]) FileEntry(name, FileKind.directory),
      const FileEntry('item.txt', FileKind.file, size: 1),
    ];
  }

  @override
  Future<void> mkdir(String path) async {
    await mutation?.future;
  }

  @override
  Future<void> close() async => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Server extends FakeTransport {
  _Server(this.folders, this.opened);
  final Map<String, List<String>> folders;
  final List<_Files> opened;
  Completer<FileSystem>? opening;

  @override
  Future<FileSystem> openFiles() async {
    if (opening != null) return opening!.future;
    final files = _Files(folders);
    opened.add(files);
    return files;
  }
}

void main() {
  const host = Host(id: HostId('memory-test'), label: 'box', address: 'memory.invalid', username: 'test');
  late ConnectionManager connections;
  late _Server server;
  late Map<String, List<String>> folders;
  late List<_Files> opened;

  setUp(() {
    folders = {};
    opened = [];
    connections = ConnectionManager((_, _, _) async {
      server = _Server(folders, opened);
      return server;
    }, park: Duration.zero);
  });
  tearDown(() => connections.closeAll());

  Future<FileBrowser> browser({String at = '/'}) async {
    final b = FileBrowser(connections);
    addTearDown(b.dispose);
    await b.open(host, NoPrompts(), at: at);
    return b;
  }

  test('back and forward retain at most 100 paths', () async {
    final b = await browser();
    for (var i = 0; i < 150; i++) {
      await b.go('/p$i');
    }
    for (var i = 0; i < 110; i++) {
      await b.back();
    }
    expect(b.path, '/p49');
    expect(b.canBack, isFalse);
    for (var i = 0; i < 110; i++) {
      await b.forward();
    }
    expect(b.path, '/p149');
    expect(b.canForward, isFalse);
  });

  test('idle release keeps metadata and navigation without closing independent file resources', () async {
    final b = await browser(at: '/first');
    await b.go('/second');
    b.setSort(FileSort.size);
    b.setFilter('item');
    final background = await connections.acquire(host, NoPrompts(), purpose: LeasePurpose.files);
    final backgroundFiles = await background.openFiles() as _Files;
    addTearDown(() async {
      await backgroundFiles.close();
      background.release();
    });
    final browsing = b.fs as _Files;
    expect(b.suspend(), isTrue);
    await pumpEventQueue();
    expect(b.entries, isEmpty);
    expect(b.fs, isNull);
    expect(b.path, '/second');
    expect(b.host, host);
    expect(b.sort, FileSort.size);
    expect(b.filter, 'item');
    expect(browsing.closed, isTrue);
    expect(backgroundFiles.closed, isFalse);
    expect(background.lost, isFalse);
    await b.resume(NoPrompts());
    expect(b.ready, isTrue);
    expect(b.entries, isNotEmpty);
    expect(b.path, '/second');
    expect(b.filter, 'item');
    await b.back();
    expect(b.path, '/first');
  });

  test('resuming an unopened pane does not open a file system', () async {
    final b = FileBrowser(connections);
    addTearDown(b.dispose);
    expect(b.suspend(), isTrue);
    await b.resume(NoPrompts());
    expect(b.status, BrowserStatus.idle);
    expect(b.fs, isNull);
    expect(opened, isEmpty);
  });

  test('idle cleanup waits for mutations to finish', () async {
    final b = await browser();
    final files = b.fs as _Files;
    files.mutation = Completer<void>();
    final modifying = b.mkdir('new');
    expect(b.suspend(), isFalse);
    expect(files.closed, isFalse);
    files.mutation!.complete();
    expect(await modifying, isNull);
    expect(b.suspend(), isTrue);
    await pumpEventQueue();
    expect(files.closed, isTrue);
  });

  test('a listing that finishes after idle release cannot restore old entries', () async {
    final b = await browser();
    final files = b.fs as _Files;
    files.slowPath = '/late';
    files.listing = Completer<List<FileEntry>>();
    final listing = b.go('/late');
    expect(b.suspend(), isTrue);
    files.listing!.complete([const FileEntry('stale.txt', FileKind.file)]);
    expect(await listing, isFalse);
    expect(b.entries, isEmpty);
    expect(b.path, '/');
    expect(b.loading, isFalse);
    await b.resume(NoPrompts());
    expect(b.path, '/');
    expect(b.entries.single.name, 'item.txt');
  });

  test('a channel that opens after idle release is closed and cannot revive the browser', () async {
    final hold = await connections.acquire(host, NoPrompts());
    addTearDown(hold.release);
    final late = _Files(folders);
    server.opening = Completer<FileSystem>();
    final b = FileBrowser(connections);
    addTearDown(b.dispose);
    final connecting = b.open(host, NoPrompts(), at: '/late');
    await pumpEventQueue();
    expect(b.status, BrowserStatus.connecting);
    expect(b.suspend(), isTrue);
    server.opening!.complete(late);
    await connecting;
    await pumpEventQueue();
    expect(late.closed, isTrue);
    expect(b.fs, isNull);
    expect(b.path, '/late');
    expect(b.status, BrowserStatus.idle);
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-files-memory-');
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          connectionManagerProvider.overrideWithValue(connections),
        ],
        child: MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('file headings align with rows outside the scrollbar gutter', (tester) async {
    folders['/'] = [for (var i = 0; i < 40; i++) 'folder-$i'];
    final b = await browser();
    await pumpPage(tester, FilePane(browser: b));
    final name = tester.getRect(find.text('Name'));
    final entry = tester.getRect(find.text('folder-0'));
    expect(name.left, entry.left);
    final header = find.ancestor(of: find.text('Name'), matching: find.byType(ScrollGutter));
    expect(header, findsOneWidget);
    final headerContent = tester.getRect(find.descendant(of: header, matching: find.byType(Row)).first);
    final list = tester.getRect(find.byType(ListView).first);
    expect(list.right - headerContent.right, ScrollSize.gutter + Space.md);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden side panel releases after idle and follows the latest directory on return', (tester) async {
    final active = ValueNotifier(true);
    final directory = _ObservedValue<String?>('/first');
    addTearDown(active.dispose);
    addTearDown(directory.dispose);
    await pumpPage(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, visible, _) => SideFilesPanel(host: host, active: visible, directory: directory, tree: true),
      ),
    );
    final b = tester.widget<FilePane>(find.byType(FilePane)).browser;
    final first = b.fs as _Files;
    active.value = false;
    await tester.pump();
    expect(directory.observed, isFalse);
    directory.value = '/latest';
    await tester.pump(const Duration(seconds: 29));
    expect(first.closed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(first.closed, isTrue);
    expect(b.entries, isEmpty);
    expect(b.path, '/first');
    active.value = true;
    await tester.pumpAndSettle();
    expect(directory.observed, isTrue);
    expect(b.path, '/latest');
    expect(b.ready, isTrue);
  });

  testWidgets('returning before idle keeps the channel; disposing cancels the idle timer', (tester) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await pumpPage(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, visible, _) => SideFilesPanel(host: host, active: visible),
      ),
    );
    active.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    active.value = true;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(opened, hasLength(1));
    expect(opened.single.closed, isFalse);
    active.value = false;
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
    expect(opened.single.closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone file page releases its opened panes and leaves the empty pane unopened', (tester) async {
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await pumpPage(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, visible, _) => FilesPage(active: visible),
      ),
    );
    final panes = tester.widgetList<FilePane>(find.byType(FilePane)).toList();
    await panes.first.browser.open(host, NoPrompts(), at: '/remote');
    active.value = true;
    await tester.pumpAndSettle();
    active.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(panes.first.browser.fs, isNull);
    expect(panes.first.browser.entries, isEmpty);
    active.value = true;
    await tester.pumpAndSettle();
    expect(panes.first.browser.path, '/remote');
    expect(panes.first.browser.ready, isTrue);
    expect(panes.last.browser.fs, isNull);
    expect(panes.last.browser.status, BrowserStatus.idle);
  });

  testWidgets('the idle timer retries after an in-flight mutation finishes', (tester) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await pumpPage(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, visible, _) => SideFilesPanel(host: host, active: visible),
      ),
    );
    final b = tester.widget<FilePane>(find.byType(FilePane)).browser;
    final files = b.fs as _Files;
    files.mutation = Completer<void>();
    final modifying = b.mkdir('new');
    active.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(files.closed, isFalse);
    files.mutation!.complete();
    expect(await modifying, isNull);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(files.closed, isTrue);
    expect(b.entries, isEmpty);
  });

  testWidgets('a late resume cannot ask for a secret after the panel is hidden again', (tester) async {
    connections.closeAll();
    final gate = Completer<void>();
    var dials = 0;
    var asked = false;
    SecretAnswer? answer;
    connections = ConnectionManager((_, prompts, _) async {
      if (++dials == 1) return _Server(folders, opened);
      await gate.future;
      asked = true;
      answer = await prompts.secret(const SecretRequest(SecretKind.password));
      throw const ConnectError(ConnectFailure.cancelled);
    }, park: Duration.zero);
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await pumpPage(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, visible, _) => SideFilesPanel(host: host, active: visible),
      ),
    );
    active.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    active.value = true;
    // This connection is deliberately waiting at the gate, so its loading animation cannot settle yet.
    await tester.pump();
    expect(dials, 2);
    active.value = false;
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(asked, isTrue);
    expect(answer, isNull);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a protected wide directory is complete and becomes reclaimable after leaving', (tester) async {
    folders['/'] = ['wide', 'other'];
    folders['/wide'] = [for (var i = 0; i < 9000; i++) 'd${i.toString().padLeft(4, '0')}'];
    final b = await browser(at: '/wide');
    await pumpPage(tester, DirectoryTree(browser: b));
    final files = b.fs as _Files;
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pump();
    expect(find.text('d8999'), findsOneWidget, reason: 'the cache target never truncates a directory');
    await b.go('/other');
    await tester.pumpAndSettle();
    await b.go('/wide/d8999');
    await tester.pumpAndSettle();
    expect(files.listed.where((path) => path == '/wide'), hasLength(2));
  });

  for (final (branches, children) in [(140, 1), (24, 500)]) {
    testWidgets('tree evicts old branches at the directory or entry target ($branches x $children)', (tester) async {
      folders['/'] = [for (var i = 0; i < branches; i++) 'd$i'];
      for (var i = 0; i < branches; i++) {
        folders['/d$i'] = [for (var j = 0; j < children; j++) 'sub$j'];
      }
      final b = await browser(at: '/d0/sub0');
      await pumpPage(tester, DirectoryTree(browser: b));
      final files = b.fs as _Files;
      expect(files.listed.where((path) => path == '/d0'), hasLength(1));
      for (var i = 1; i < branches; i++) {
        await b.go('/d$i/sub0');
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await b.go('/d0/sub0');
      await tester.pumpAndSettle();
      expect(files.listed.where((path) => path == '/d0'), hasLength(2), reason: 'an evicted ancestor is read again');
      expect(b.entries, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }
}
