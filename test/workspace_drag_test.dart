import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/interface_scale.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/features/workspace/domain/layout.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

const _shell = LocalShell(kind: LocalShellKind.cmd, executable: r'C:\Windows\System32\cmd.exe');

class _Pty implements LocalPty {
  final bytes = StreamController<Uint8List>();
  final exited = Completer<int>();
  final writes = <String>[];
  var closes = 0;
  @override
  Stream<Uint8List> get output => bytes.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  void write(Uint8List data) => writes.add(String.fromCharCodes(data));
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (exited.isCompleted) return;
    closes++;
    bytes.close();
    exited.complete(0);
  }
}

class _Factory implements LocalPtyFactory {
  final opened = <_Pty>[];
  @override
  Future<LocalPty> start(LocalShell shell, {required int cols, required int rows, CancellationToken? cancel}) async {
    final pty = _Pty();
    opened.add(pty);
    return pty;
  }
}

class _Hosts extends HostsNotifier {
  @override
  List<Host> build() => const [Host(id: HostId('test'), label: 'test', address: 'example.com', username: 'u')];
}

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  late _Factory factory;
  late Workspace ws;

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> mount(WidgetTester tester, {double scale = 1}) async {
    dir = Directory.systemTemp.createTempSync('sshairy-drag-');
    factory = _Factory();
    container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        hostsProvider.overrideWith(_Hosts.new),
        localPtyProvider.overrideWithValue(factory),
      ],
    );
    ws = container.read(workspaceProvider.notifier);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var done = false;
      final pending = Future.wait([
        ws.saved,
        container.read(settingsProvider.notifier).saved,
        container.read(terminalSessionsProvider.notifier).shutdown(),
      ]).then((_) => done = true);
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done, isTrue);
      await pending;
      container.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _Assets(),
          child: MaterialApp(
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            builder: (_, child) => InterfaceScale(scale: scale, child: child!),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    await frames(tester);
  }

  WorkspaceTab tab(TabId id) => container.read(workspaceProvider).tabs.firstWhere((t) => t.id == id);
  Finder topTab(TabId id) => find.byKey(ValueKey('tab-drop-${id.value}'));
  Finder pane(PaneId id) => find.byKey(ValueKey('pane-drop-${id.value}'));
  Offset edge(Rect rect, PaneSide side) => switch (side) {
    PaneSide.left => Offset(rect.left + 16, rect.center.dy),
    PaneSide.right => Offset(rect.right - 16, rect.center.dy),
    PaneSide.top => Offset(rect.center.dx, rect.top + 16),
    PaneSide.bottom => Offset(rect.center.dx, rect.bottom - 16),
  };

  Future<TestGesture> startDrag(WidgetTester tester, Finder source) async {
    final start = tester.getCenter(source);
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, 28));
    await frames(tester);
    return gesture;
  }

  for (final side in PaneSide.values) {
    testWidgets('tab moves existing terminal to ${side.name} with preview and preserved pane state', (tester) async {
      await mount(tester);
      final source = ws.openLocal(_shell);
      ws.rename(source, 'source');
      await frames(tester);
      final sourceLeaf = tab(source).layout.focusedLeaf;
      final session = ws.session(sourceLeaf.session)!;
      session.multilineDraft = 'echo preserved';
      final sourceView = tester.state(find.byType(TerminalPane).last);
      final target = ws.openLocal(_shell);
      ws.rename(target, 'target');
      await frames(tester);
      final targetLeaf = tab(target).layout.focusedLeaf;
      final gesture = await startDrag(tester, topTab(source));
      await gesture.moveTo(edge(tester.getRect(pane(targetLeaf.pane)), side));
      await frames(tester);
      expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
      final preview = tester.getRect(find.byKey(const ValueKey('pane-drop-preview')));
      final targetRect = tester.getRect(pane(targetLeaf.pane));
      expect(targetRect.contains(preview.center), isTrue);
      await gesture.up();
      await frames(tester);
      expect(container.read(workspaceProvider).tabs, hasLength(1));
      final layout = tab(target).layout;
      expect((layout.root as PaneSplit).axis, side.axis);
      expect(
        layout.leaves.map((leaf) => leaf.pane),
        side.before ? [sourceLeaf.pane, targetLeaf.pane] : [targetLeaf.pane, sourceLeaf.pane],
      );
      expect(layout.focused, sourceLeaf.pane);
      expect(identical(ws.session(sourceLeaf.session), session), isTrue);
      final movedView = find.descendant(of: pane(sourceLeaf.pane), matching: find.byType(TerminalPane));
      expect(identical(tester.state(movedView), sourceView), isTrue);
      expect(session.multilineDraft, 'echo preserved');
      expect(factory.opened, hasLength(2));
      expect(factory.opened.every((p) => p.closes == 0), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final side in PaneSide.values) {
    testWidgets('the visible tab creates a fresh split on ${side.name} without replacing its session', (tester) async {
      await mount(tester);
      final id = ws.openLocal(_shell);
      await frames(tester);
      final original = tab(id).layout.focusedLeaf;
      final session = ws.session(original.session)!;
      session.multilineDraft = 'keep this draft';
      final view = tester.state(find.byType(TerminalPane));
      final gesture = await startDrag(tester, topTab(id));
      await gesture.moveTo(edge(tester.getRect(pane(original.pane)), side));
      await frames(tester);
      expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
      expect(factory.opened, hasLength(1), reason: 'preview must not start a process');
      await gesture.up();
      await frames(tester);
      final layout = tab(id).layout;
      expect(container.read(workspaceProvider).tabs, hasLength(1));
      expect((layout.root as PaneSplit).axis, side.axis);
      final leaves = layout.leaves.toList();
      expect(leaves[side.before ? 1 : 0].pane, original.pane);
      final added = leaves[side.before ? 0 : 1];
      expect(added.session, isNot(original.session));
      expect(layout.focused, added.pane);
      expect(ws.session(added.session)!.localShell, _shell);
      expect(identical(ws.session(original.session), session), isTrue);
      expect(
        identical(tester.state(find.descendant(of: pane(original.pane), matching: find.byType(TerminalPane))), view),
        isTrue,
      );
      expect(session.multilineDraft, 'keep this draft');
      expect(factory.opened, hasLength(2));
      expect(factory.opened.every((p) => p.closes == 0), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the visible split tab adds only one session at the targeted pane', (tester) async {
    await mount(tester);
    final id = ws.openLocal(_shell);
    ws.split(SplitAxis.horizontal);
    await frames(tester);
    final leaves = tab(id).layout.leaves.toList();
    final gesture = await startDrag(tester, topTab(id));
    await gesture.moveTo(edge(tester.getRect(pane(leaves.first.pane)), PaneSide.bottom));
    await frames(tester);
    await gesture.up();
    await frames(tester);
    expect(tab(id).layout.leaves, hasLength(3));
    final root = tab(id).layout.root as PaneSplit;
    expect(root.ratios, [0.5, 0.5]);
    expect(root.children.last, isA<Leaf>());
    expect((root.children.last as Leaf).pane, leaves.last.pane);
    expect((root.children.first as PaneSplit).axis, SplitAxis.vertical);
    expect(factory.opened, hasLength(3));
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a split tab moves as a group into one target pane', (tester) async {
    await mount(tester);
    final source = ws.openLocal(_shell);
    ws.split(SplitAxis.vertical);
    await frames(tester);
    final incoming = tab(source).layout;
    final target = ws.openLocal(_shell);
    ws.split(SplitAxis.vertical);
    await frames(tester);
    final original = tab(target).layout;
    final targetLeaf = original.leaves.first;
    final gesture = await startDrag(tester, topTab(source));
    await gesture.moveTo(edge(tester.getRect(pane(targetLeaf.pane)), PaneSide.left));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs, hasLength(1));
    expect(tab(target).layout.leaves, hasLength(4));
    expect(tab(target).layout.leaves.map((leaf) => leaf.pane), [
      ...incoming.leaves.map((l) => l.pane),
      ...original.leaves.map((l) => l.pane),
    ]);
    expect(factory.opened, hasLength(4));
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pane header moves within a split then detaches back to the tab strip', (tester) async {
    await mount(tester);
    final id = ws.openLocal(_shell);
    ws.split(SplitAxis.horizontal);
    await frames(tester);
    final leaves = tab(id).layout.leaves.toList();
    var gesture = await startDrag(tester, find.byKey(ValueKey('pane-drag-${leaves.first.pane.value}')));
    await gesture.moveTo(edge(tester.getRect(pane(leaves.last.pane)), PaneSide.bottom));
    await frames(tester);
    await gesture.up();
    await frames(tester);
    expect((tab(id).layout.root as PaneSplit).axis, SplitAxis.vertical);
    expect(tab(id).layout.leaves.map((l) => l.pane), [leaves.last.pane, leaves.first.pane]);
    gesture = await startDrag(tester, find.byKey(ValueKey('pane-drag-${leaves.first.pane.value}')));
    final strip = tester.getRect(find.byKey(const ValueKey('workspace-tab-strip')));
    await gesture.moveTo(Offset(strip.right - 8, strip.center.dy));
    await frames(tester);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    expect(tab(id).layout.leaves.single.pane, leaves.last.pane);
    expect(container.read(workspaceProvider).activeTab!.layout.leaves.single.pane, leaves.first.pane);
    expect(factory.opened, hasLength(2));
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hover changes target tab and Escape cancels without moving terminals', (tester) async {
    await mount(tester, scale: 1.5);
    final target = ws.openLocal(_shell);
    final source = ws.openLocal(_shell);
    await frames(tester);
    final before = tab(source).layout;
    final gesture = await startDrag(tester, topTab(source));
    await gesture.moveTo(tester.getCenter(topTab(target)));
    await tester.pump(const Duration(milliseconds: 500));
    await frames(tester);
    expect(container.read(workspaceProvider).active, target);
    final targetLeaf = tab(target).layout.focusedLeaf;
    await gesture.moveTo(edge(tester.getRect(pane(targetLeaf.pane)), PaneSide.right));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsNothing);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    expect(identical(tab(source).layout, before), isTrue);
    expect(container.read(workspaceProvider).active, source);
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow same-tab moves validate the layout after removing the source', (tester) async {
    await mount(tester);
    final id = ws.openLocal(_shell);
    ws.split(SplitAxis.horizontal);
    tester.view.physicalSize = const Size(500, 700);
    await frames(tester);
    final leaves = tab(id).layout.leaves.toList();
    expect(tester.getSize(pane(leaves.last.pane)).width, lessThan(240));
    final gesture = await startDrag(tester, find.byKey(ValueKey('pane-drag-${leaves.first.pane.value}')));
    await gesture.moveTo(edge(tester.getRect(pane(leaves.last.pane)), PaneSide.right));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
    await gesture.up();
    await frames(tester);
    expect(tab(id).layout.leaves.map((leaf) => leaf.pane), [leaves.last.pane, leaves.first.pane]);
    expect(factory.opened, hasLength(2));
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('insufficient space rejects a group while keeping its sessions', (tester) async {
    await mount(tester);
    final source = ws.openLocal(_shell);
    ws.split(SplitAxis.horizontal);
    final target = ws.openLocal(_shell);
    tester.view.physicalSize = const Size(500, 700);
    await frames(tester);
    final before = tab(target).layout;
    final gesture = await startDrag(tester, topTab(source));
    await gesture.moveTo(edge(tester.getRect(pane(before.focused)), PaneSide.left));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsNothing);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    expect(identical(tab(target).layout, before), isTrue);
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the source during drag releases the keyboard handler', (tester) async {
    await mount(tester);
    final source = ws.openLocal(_shell);
    final target = ws.openLocal(_shell);
    await frames(tester);
    final gesture = await startDrag(tester, topTab(source));
    ws.closeTab(source);
    await frames(tester);
    await gesture.up();
    await frames(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(tester);
    final search = tester.widget<TextField>(find.byKey(const ValueKey('command-history-search')));
    search.focusNode!.requestFocus();
    await frames(tester);
    expect(search.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester);
    expect(find.byKey(const ValueKey('command-history-popup')), findsNothing);
    expect(container.read(workspaceProvider).tabs.single.id, target);
    expect(factory.opened.map((p) => p.closes), [1, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape cancels dragging before a pinned history search can consume it', (tester) async {
    await mount(tester);
    final source = ws.openLocal(_shell);
    final target = ws.openLocal(_shell);
    await frames(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(tester);
    await tester.tap(find.byTooltip('Pin'));
    await frames(tester);
    final gesture = await startDrag(tester, topTab(source));
    final leaf = tab(target).layout.focusedLeaf;
    final rect = tester.getRect(pane(leaf.pane));
    await gesture.moveTo(Offset(rect.right - 16, rect.bottom - 150));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('command-history-popup')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsNothing);
    expect(find.byKey(const ValueKey('command-history-popup')), findsOneWidget);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    final search = tester.widget<TextField>(find.byKey(const ValueKey('command-history-search')));
    search.focusNode!.requestFocus();
    await frames(tester);
    expect(search.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester);
    expect(find.byKey(const ValueKey('command-history-popup')), findsNothing);
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one pane moves across split tabs without leaving a drag handler behind', (tester) async {
    await mount(tester);
    final source = ws.openLocal(_shell);
    ws.split(SplitAxis.horizontal);
    final incoming = tab(source).layout.focusedLeaf;
    final target = ws.openLocal(_shell);
    ws.split(SplitAxis.vertical);
    ws.activate(source);
    await frames(tester);
    final view = tester.state(find.descendant(of: pane(incoming.pane), matching: find.byType(TerminalPane)));
    final gesture = await startDrag(tester, find.byKey(ValueKey('pane-drag-${incoming.pane.value}')));
    await gesture.moveTo(tester.getCenter(topTab(target)));
    await tester.pump(const Duration(milliseconds: 500));
    await frames(tester);
    final targetPane = tab(target).layout.leaves.first.pane;
    await gesture.moveTo(edge(tester.getRect(pane(targetPane)), PaneSide.right));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
    await gesture.up();
    await frames(tester);
    expect(tab(source).layout.leaves, hasLength(1));
    expect(tab(target).layout.leaves, hasLength(3));
    expect(tab(target).layout.focused, incoming.pane);
    expect(
      identical(tester.state(find.descendant(of: pane(incoming.pane), matching: find.byType(TerminalPane))), view),
      isTrue,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(tester);
    tester.widget<TextField>(find.byKey(const ValueKey('command-history-search'))).focusNode!.requestFocus();
    await frames(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester);
    expect(find.byKey(const ValueKey('command-history-popup')), findsNothing);
    expect(factory.opened, hasLength(4));
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a changed source layout invalidates an in-flight drag', (tester) async {
    await mount(tester);
    final source = ws.openLocal(_shell);
    final target = ws.openLocal(_shell);
    await frames(tester);
    final before = tab(target).layout;
    final gesture = await startDrag(tester, topTab(source));
    await gesture.moveTo(edge(tester.getRect(pane(before.focused)), PaneSide.left));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsOneWidget);
    ws.activate(source);
    ws.split(SplitAxis.vertical);
    ws.activate(target);
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsNothing);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    expect(identical(tab(target).layout, before), isTrue);
    expect(factory.opened, hasLength(3));
    expect(factory.opened.every((p) => p.closes == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('central drops do nothing and horizontal drags still reorder tabs', (tester) async {
    await mount(tester);
    final first = ws.openLocal(_shell);
    final second = ws.openLocal(_shell);
    await frames(tester);
    final original = tab(second).layout;
    var gesture = await startDrag(tester, topTab(first));
    await gesture.moveTo(tester.getCenter(pane(original.focused)));
    await frames(tester);
    expect(find.byKey(const ValueKey('pane-drop-preview')), findsNothing);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    gesture = await startDrag(tester, topTab(first));
    final secondRect = tester.getRect(topTab(second));
    await gesture.moveTo(Offset(secondRect.right - 8, secondRect.center.dy));
    await frames(tester);
    await gesture.up();
    await frames(tester);
    expect(container.read(workspaceProvider).tabs.map((t) => t.id), [second, first]);
    expect(factory.opened, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
