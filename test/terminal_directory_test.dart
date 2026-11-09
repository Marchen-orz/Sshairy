import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/dock_panel.dart';
import 'package:sshairy/design/menu.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/api.dart' show SideFilesPanel;
import 'package:sshairy/features/files/presentation/directory_tree.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/terminal/domain/directory.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

class _Shell implements ShellChannel {
  final out = StreamController<Uint8List>();
  final ended = Completer<void>();
  @override
  Stream<Uint8List> get stdout => out.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => ended.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (!ended.isCompleted) ended.complete();
    out.close();
  }
}

/// A server whose shell sits in [cwd]; the marker query answers with it.
class _Server extends FakeTransport {
  Map<String, String>? environment;
  final opened = <_Shell>[];
  final queries = <String>[];
  final calls = <({CancellationToken? cancel, Duration? timeout})>[];
  var active = 0, peak = 0, cancelled = 0, timedOut = 0;
  String? cwd;
  Completer<ExecResult>? pendingQuery;
  _Files? files;

  @override
  Future<ShellChannel> openShell({
    required int cols,
    required int rows,
    Map<String, String> environment = const {},
  }) async {
    this.environment = environment;
    final shell = _Shell();
    opened.add(shell);
    return shell;
  }

  @override
  Future<ExecResult> exec(String command, {int limit = 0, Duration? timeout, CancellationToken? cancel}) async {
    queries.add(command);
    calls.add((cancel: cancel, timeout: timeout));
    active++;
    if (active > peak) peak = active;
    try {
      if (pendingQuery case final pending?) {
        final waiting = Future.any<ExecResult>([
          pending.future,
          if (cancel != null) cancel.whenCancelled.then((_) => throw const ExecError(ExecFailure.cancelled)),
        ]);
        return await (timeout == null
            ? waiting
            : waiting.timeout(timeout, onTimeout: () => throw const ExecError(ExecFailure.timedOut)));
      }
      final out = cwd == null ? '' : '$cwd\n';
      return ExecResult(Uint8List.fromList(utf8.encode(out)), Uint8List(0), 0);
    } on ExecError catch (error) {
      if (error.kind == ExecFailure.cancelled) cancelled++;
      if (error.kind == ExecFailure.timedOut) timedOut++;
      rethrow;
    } finally {
      active--;
    }
  }

  @override
  Future<FileSystem> openFiles() async => files!;
}

/// Folders by path, each with one file so the list is never empty.
class _Files implements FileSystem {
  _Files(this.tree);

  final Map<String, List<String>> tree;
  final listed = <String>[];

  @override
  PathStyle get style => PathStyle.posix;
  @override
  bool get canReplace => false;
  @override
  bool get canChmod => false;
  @override
  Future<String> home() async => '/home/u';
  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<FileEntry>> list(String dir) async {
    listed.add(dir);
    final folders = tree[dir];
    if (folders == null) throw const FsError(FsFailure.notFound);
    final name = dir == '/' ? 'root' : dir.split('/').last;
    return [for (final f in folders) FileEntry(f, FileKind.directory), FileEntry('$name.txt', FileKind.file, size: 1)];
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  const host = Host(id: HostId('h'), label: 'box', address: 'h', username: 'u');

  group('query', () {
    test('is a constant read-only script around a hex marker', () {
      final command = directoryQuery('0123456789abcdef');
      expect(command, startsWith("sh -c '"));
      expect(command, contains('LC_SSHAIRY_SESSION=0123456789abcdef'));
      expect("'".allMatches(command), hasLength(2), reason: 'nothing inside closes the quoting');
      expect(command, isNot(contains(RegExp(r'\brm\b|>\s*[^&/=]|\bsudo\b|\bkill\b|\btee\b|\bdd\b'))));
      for (final bad in ['', '0123456789ABCDEF', "0123456789abcde'", '0123456789abcdef0']) {
        expect(() => directoryQuery(bad), throwsArgumentError, reason: bad);
      }
    });

    test('the last path printed wins; nothing or a deleted directory gives none', () {
      expect(parseDirectoryQuery('/home/u\n/home/u/src\n'), '/home/u/src');
      expect(parseDirectoryQuery('/srv/my dir\r\n'), '/srv/my dir');
      expect(parseDirectoryQuery(''), isNull);
      expect(parseDirectoryQuery('grep: oops\n'), isNull);
      expect(parseDirectoryQuery('/tmp/x (deleted)\n'), isNull);
    });

    test('OSC 7 gives a decoded absolute path and nothing else', () {
      expect(parseOsc7('file://box/home/u/a%20b'), '/home/u/a b');
      expect(parseOsc7('file:///srv'), '/srv');
      expect(parseOsc7('http://box/srv'), isNull);
      expect(parseOsc7('not a uri at all'), isNull);
    });
  });

  group('session', () {
    late _Server server;
    late ConnectionManager manager;
    late TerminalSession session;

    Future<void> connect(WidgetTester tester) async {
      server = _Server();
      manager = ConnectionManager((_, _, _) async => server, park: Duration.zero);
      session = TerminalSession(const SessionId('s'), host, manager);
      addTearDown(() {
        session.close();
        manager.closeAll();
      });
      unawaited(session.connect(NoPrompts()));
      await tester.pump();
      await tester.pump();
      expect(session.canInsert, isTrue);
    }

    Future<void> enter(String command) => session.insert(command, run: true, confirm: (_) async => true);

    testWidgets('the shell carries a marker, looked up only while someone follows the directory', (tester) async {
      await connect(tester);
      final marker = server.environment?['LC_SSHAIRY_SESSION'];
      expect(marker, matches(RegExp(r'^[0-9a-f]{16}$')));
      await enter('cd /srv');
      await tester.pump(const Duration(seconds: 2));
      expect(server.queries, isEmpty, reason: 'nobody follows yet');

      server.cwd = '/srv/app';
      void listener() {}
      session.directory.addListener(listener);
      await tester.pump(Duration.zero);
      expect(server.queries, [contains(marker)]);
      expect(session.directory.value, '/srv/app');

      server.cwd = '/tmp';
      await enter('cd /tmp');
      await tester.pump(const Duration(milliseconds: 400));
      expect(session.directory.value, '/tmp');
      await tester.pump(const Duration(milliseconds: 1100));
      expect(server.queries, hasLength(3), reason: 'once soon after Enter and once more for a slow command');

      session.directory.removeListener(listener);
      await enter('cd /');
      await tester.pump(const Duration(seconds: 2));
      expect(server.queries, hasLength(3));
    });

    testWidgets('a directory lookup from before Enter cannot restore the previous directory', (tester) async {
      await connect(tester);
      final pending = Completer<ExecResult>();
      server.pendingQuery = pending;
      void follow() {}
      session.directory.addListener(follow);
      addTearDown(() => session.directory.removeListener(follow));
      await tester.pump(Duration.zero);
      expect(server.queries, hasLength(1));
      await enter('cd /next');
      expect(server.calls.single.cancel!.isCancelled, isTrue);
      pending.complete(ExecResult(Uint8List.fromList(utf8.encode('/previous\n')), Uint8List(0), 0));
      await tester.pump();
      expect(server.active, 0);
      expect(session.directory.value, isNull);
      server.pendingQuery = null;
      server.cwd = '/next';
      await tester.pump(const Duration(milliseconds: 400));
      expect(session.directory.value, '/next');
      session.directory.removeListener(follow);
    });

    testWidgets('directory timeouts drain before another query and closing cancels the pending query', (tester) async {
      await connect(tester);
      final pending = Completer<ExecResult>();
      server.pendingQuery = pending;
      void follow() {}
      session.directory.addListener(follow);
      await tester.pump(Duration.zero);
      expect(server.active, 1);
      expect(server.calls.single.timeout, const Duration(seconds: 5));
      expect(server.calls.single.cancel, isNotNull);
      await tester.pump(const Duration(seconds: 5));
      expect(server.timedOut, 1);
      expect(server.active, 0);
      expect(session.directory.value, isNull);

      await enter('cd /next');
      await tester.pump(const Duration(milliseconds: 400));
      expect(server.queries, hasLength(2));
      expect(server.active, 1);
      expect(server.peak, 1);
      session.close();
      expect(server.calls.last.cancel!.isCancelled, isTrue);
      await tester.pump();
      expect(server.active, 0);
      expect(server.cancelled, 1);
      pending.complete(ExecResult(Uint8List.fromList(utf8.encode('/late\n')), Uint8List(0), 0));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a lost shell cancels its query and a reconnect cannot receive the old directory', (tester) async {
      await connect(tester);
      final retained = await manager.acquire(host, NoPrompts());
      addTearDown(retained.release);
      final pending = Completer<ExecResult>();
      server.pendingQuery = pending;
      void follow() {}
      session.directory.addListener(follow);
      await tester.pump(Duration.zero);
      expect(server.active, 1);
      server.opened.single.close();
      await tester.pump();
      await tester.pump(Duration.zero); // Drain TerminalOutput's zero-delay EOF timer before reconnecting.
      expect(server.calls.single.cancel!.isCancelled, isTrue);
      expect(server.active, 0);
      expect(session.status, SessionStatus.disconnected);
      server.pendingQuery = null;
      server.cwd = '/fresh';
      unawaited(session.connect(NoPrompts()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(server.opened, hasLength(2));
      expect(session.directory.value, '/fresh');
      pending.complete(ExecResult(Uint8List.fromList(utf8.encode('/previous\n')), Uint8List(0), 0));
      await tester.pump();
      expect(session.directory.value, '/fresh');
      expect(server.active, 0);
      session.directory.removeListener(follow);
    });

    testWidgets('without the marker the OSC 7 report is used', (tester) async {
      await connect(tester);
      void listener() {}
      session.directory.addListener(listener);
      addTearDown(() => session.directory.removeListener(listener));
      server.opened.single.out.add(Uint8List.fromList(utf8.encode('\x1b]7;file://box/home/u/a%20b\x07')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(server.queries, isNotEmpty);
      expect(session.directory.value, '/home/u/a b');
    });
  });

  group('panel', () {
    const panelKey = ValueKey('file-panel');

    Future<(_Files, ValueNotifier<String?>)> pump(
      WidgetTester tester, {
      required bool tree,
      String? at,
      Map<String, List<String>>? folders,
      List<Widget> toolbarActions = const [],
      DockSide? dock,
      double width = 1200,
    }) async {
      final files = _Files(
        folders ??
            {
              '/': ['home', 'srv'],
              '/home': ['u'],
              '/home/u': ['docs'],
              '/home/u/docs': [],
              '/srv': ['app'],
              '/srv/app': [],
            },
      );
      final server = _Server()..files = files;
      final manager = ConnectionManager((_, _, _) async => server, park: Duration.zero);
      final directory = ValueNotifier<String?>(at);
      final dir = Directory.systemTemp.createTempSync('sshairy-tree-');
      addTearDown(() => dir.deleteSync(recursive: true));
      await tester.binding.setSurfaceSize(Size(width, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      final panel = SideFilesPanel(host: host, tree: tree, directory: directory, toolbarActions: toolbarActions);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dataDirProvider.overrideWithValue(dir.path),
            connectionManagerProvider.overrideWithValue(manager),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RepaintBoundary(
              key: panelKey,
              child: Scaffold(
                body: dock == null
                    ? panel
                    : DockPanel(
                        open: true,
                        side: dock,
                        showHeader: false,
                        onClose: () {},
                        closeLabel: 'Close panel',
                        resizeLabel: 'Resize panel',
                        panel: panel,
                        child: const SizedBox.expand(),
                      ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (files, directory);
    }

    Finder inTree(String text) => find.descendant(of: find.byType(DirectoryTree), matching: find.text(text));

    testWidgets('docked below, a tree beside the list follows the terminal directory', (tester) async {
      final (files, directory) = await pump(tester, tree: true, at: '/srv/app');
      expect(files.listed.first, '/srv/app', reason: 'the panel opens where the terminal is');
      expect(find.text('app.txt'), findsOneWidget);
      for (final name in ['/', 'home', 'srv', 'app']) {
        expect(inTree(name), findsOneWidget, reason: name);
      }
      expect(inTree('u'), findsNothing, reason: 'only the ancestors of the current folder open');

      directory.value = '/home/u';
      await tester.pumpAndSettle();
      expect(find.text('u.txt'), findsOneWidget);
      expect(inTree('docs'), findsOneWidget);

      await tester.tap(inTree('docs'));
      await tester.pumpAndSettle();
      expect(find.text('docs.txt'), findsOneWidget);

      await tester.tap(inTree('srv'));
      await tester.pumpAndSettle();
      expect(find.text('srv.txt'), findsOneWidget);
      directory.value = '/home/u';
      await tester.pumpAndSettle();
      expect(
        find.text('srv.txt'),
        findsOneWidget,
        reason: 'an unchanged terminal directory does not pull the panel back',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('scrolling the selected folder above the viewport does not paint over the toolbar', (tester) async {
      final names = [for (var i = 0; i < 40; i++) 'folder${i.toString().padLeft(2, '0')}'];
      await pump(tester, tree: true, at: '/folder00', folders: {'/': names, for (final name in names) '/$name': []});
      final list = find.descendant(of: find.byType(DirectoryTree), matching: find.byType(ListView));
      final viewportTop = tester.getTopLeft(list).dy;
      final selected = inTree('folder00');
      final scroll = tester.widget<ListView>(list).controller!;
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(panelKey));

      Future<List<int>> toolbarPixels() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          return [
            for (var y = 0; y < viewportTop.floor(); y++)
              ...bytes.sublist(y * image.width * 4, (y * image.width + WorkspaceSize.directoryTree.toInt()) * 4),
          ];
        } finally {
          image.dispose();
        }
      }

      final before = (await tester.runAsync(toolbarPixels))!;
      final selectedBounds = tester.getRect(selected);
      scroll.jumpTo(selectedBounds.center.dy - viewportTop - 2);
      await tester.pumpAndSettle();
      expect(selectedBounds.top - scroll.offset, lessThan(viewportTop));
      expect(selectedBounds.bottom - scroll.offset, greaterThan(viewportTop));
      final after = (await tester.runAsync(toolbarPixels))!;
      expect(after, before, reason: 'selection and ink stay inside the scrolled content');
    });

    for (final (dock, width) in [(DockSide.bottom, 1200.0), (DockSide.right, 300.0)]) {
      testWidgets('$dock keeps docking and close in the file toolbar at width $width', (tester) async {
        var closed = false;
        DockSide? chosen;
        await pump(
          tester,
          tree: dock == DockSide.bottom,
          dock: dock,
          width: width,
          toolbarActions: [
            AppMenuButton<DockSide>(
              tooltip: 'Dock position',
              icon: const Icon(Icons.space_dashboard_outlined, size: 16),
              items: () => [const AppMenuItem(value: DockSide.left, label: 'Left')],
              onSelected: (side) => chosen = side,
            ),
            IconButton(tooltip: 'Close panel', onPressed: () => closed = true, icon: const Icon(Icons.close, size: 16)),
          ],
        );
        final refresh = find.byTooltip('Refresh');
        final position = find.byTooltip('Dock position');
        final close = find.byTooltip('Close panel');
        expect(close, findsOneWidget, reason: 'there is no second panel header');
        expect(tester.getCenter(position).dy, tester.getCenter(refresh).dy);
        expect(tester.getCenter(close).dy, tester.getCenter(refresh).dy);
        expect(tester.getTopLeft(close).dy - tester.getTopLeft(find.byType(SideFilesPanel)).dy, Space.xs);
        expect(tester.takeException(), isNull, reason: 'the narrow toolbar fits');

        if (width < 560) {
          expect(find.byTooltip('Back'), findsNothing);
          await tester.tap(find.byTooltip('More'));
          await tester.pumpAndSettle();
          expect(find.text('Back'), findsOneWidget);
          expect(find.text('Forward'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        await tester.tap(position);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Left'));
        await tester.pumpAndSettle();
        expect(chosen, DockSide.left);
        await tester.tap(close);
        expect(closed, isTrue);
      });
    }

    testWidgets('docked at the side the panel has no tree', (tester) async {
      await pump(tester, tree: false);
      expect(find.byType(DirectoryTree), findsNothing);
      expect(find.text('u.txt'), findsOneWidget, reason: 'with no terminal directory yet it opens at home');
    });
  });
}
