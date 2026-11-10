import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/features/workspace/domain/layout.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';

const _shell = LocalShell(kind: LocalShellKind.cmd, executable: r'C:\Windows\System32\cmd.exe');

class _Pty implements LocalPty {
  final outputBytes = StreamController<Uint8List>();
  final ended = Completer<int>();
  var closes = 0;
  @override
  Stream<Uint8List> get output => outputBytes.stream;
  @override
  Future<int> get exitCode => ended.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (ended.isCompleted) return;
    closes++;
    outputBytes.close();
    ended.complete(0);
  }
}

class _Factory implements LocalPtyFactory {
  final started = <_Pty>[];
  @override
  Future<LocalPty> start(LocalShell shell, {required int cols, required int rows, CancellationToken? cancel}) async {
    final pty = _Pty();
    started.add(pty);
    return pty;
  }
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  late Workspace workspace;
  late _Factory factory;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-workspace-move-');
    factory = _Factory();
    container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        localPtyProvider.overrideWithValue(factory),
      ],
    );
    workspace = container.read(workspaceProvider.notifier);
  });

  tearDown(() async {
    await workspace.saved;
    await container.read(terminalSessionsProvider.notifier).shutdown();
    container.dispose();
    await dir.delete(recursive: true);
  });

  WorkspaceTab tab(TabId id) => container.read(workspaceProvider).tabs.firstWhere((t) => t.id == id);
  Map<String, dynamic> snapshot() =>
      jsonDecode(File('${dir.path}/workspace.json').readAsStringSync()) as Map<String, dynamic>;

  for (final side in PaneSide.values) {
    test('a ${side.name} drop moves an entire split tab without reopening or closing sessions', () async {
      final source = workspace.openLocal(_shell);
      workspace.rename(source, 'source');
      workspace.split(SplitAxis.vertical);
      final sourceLayout = tab(source).layout;
      final target = workspace.openLocal(_shell);
      final targetLayout = tab(target).layout;
      final sessions = Map<SessionId, TerminalSession>.from(container.read(terminalSessionsProvider));
      for (final session in sessions.values) {
        session.multilineDraft = 'draft-${session.id.value}';
        unawaited(session.connect());
      }
      await pumpEventQueue();
      await workspace.saved;
      final beforeCheck = container.read(workspaceProvider);
      final savedBytes = File('${dir.path}/workspace.json').readAsBytesSync();
      final revision = snapshot()['revision'] as int;
      expect(
        workspace.canMoveTerminal(
          sourceTabId: source,
          targetTabId: target,
          targetPaneId: targetLayout.focused,
          side: side,
          expectedSource: sourceLayout,
          expectedTarget: targetLayout,
        ),
        isTrue,
      );
      expect(identical(container.read(workspaceProvider), beforeCheck), isTrue);
      expect(File('${dir.path}/workspace.json').readAsBytesSync(), savedBytes);
      var notifications = 0;
      final subscription = container.listen(workspaceProvider, (_, _) => notifications++);
      expect(
        workspace.moveTerminal(
          sourceTabId: source,
          targetTabId: target,
          targetPaneId: targetLayout.focused,
          side: side,
          expectedSource: sourceLayout,
          expectedTarget: targetLayout,
        ),
        isTrue,
      );
      expect(notifications, 1);
      subscription.close();
      final state = container.read(workspaceProvider);
      expect(state.tabs, hasLength(1));
      expect(state.active, target);
      final moved = state.tabs.single.layout;
      expect(moved.focused, sourceLayout.focused);
      expect(identical((moved.root as PaneSplit).children[side.before ? 0 : 1], sourceLayout.root), isTrue);
      expect(container.read(terminalSessionsProvider), sessions);
      expect(
        sessions.values.every((s) => s.multilineDraft == 'draft-${s.id.value}' && s.status == SessionStatus.connected),
        isTrue,
      );
      expect(factory.started, hasLength(3));
      expect(factory.started.every((p) => p.closes == 0), isTrue);
      await workspace.saved;
      expect((snapshot()['tabs'] as List), hasLength(1));
      expect(snapshot()['revision'], revision + 1);
    });
  }

  test('moving one pane between split tabs collapses the source and preserves unrelated target ratios', () {
    final source = workspace.openLocal(_shell);
    workspace.rename(source, 'source');
    workspace.split(SplitAxis.vertical);
    final sourcePanes = tab(source).layout.leaves.toList();
    final target = workspace.openLocal(_shell);
    workspace.rename(target, 'target');
    workspace.split(SplitAxis.horizontal);
    workspace.resize(target, const [], [1, 3]);
    final targetPanes = tab(target).layout.leaves.toList();
    expect(
      workspace.moveTerminal(
        sourceTabId: source,
        sourcePaneId: sourcePanes.last.pane,
        targetTabId: target,
        targetPaneId: targetPanes.last.pane,
        side: PaneSide.left,
      ),
      isTrue,
    );
    expect(tab(source).layout.root, isA<Leaf>());
    expect(tab(source).layout.focused, sourcePanes.first.pane);
    expect(tab(source).title, 'source');
    expect(tab(target).title, 'target');
    expect((tab(target).layout.root as PaneSplit).ratios, [0.25, 0.375, 0.375]);
    expect(tab(target).layout.leaves.map((l) => l.pane), [
      targetPanes.first.pane,
      sourcePanes.last.pane,
      targetPanes.last.pane,
    ]);
    expect(container.read(terminalSessionsProvider), hasLength(4));
  });

  test('merging two split groups preserves the source subtree and unrelated target shares', () {
    final source = workspace.openLocal(_shell);
    workspace.split(SplitAxis.vertical);
    workspace.resize(source, const [], [1, 3]);
    final incoming = tab(source).layout;
    final target = workspace.openLocal(_shell);
    workspace.split(SplitAxis.horizontal);
    workspace.resize(target, const [], [2, 3]);
    final focused = tab(target).layout.focused;
    expect(
      workspace.moveTerminal(sourceTabId: source, targetTabId: target, targetPaneId: focused, side: PaneSide.right),
      isTrue,
    );
    final root = tab(target).layout.root as PaneSplit;
    expect(root.ratios, [0.4, 0.3, 0.3]);
    expect(identical(root.children.last, incoming.root), isTrue);
    expect((root.children.last as PaneSplit).ratios, [0.25, 0.75]);
    expect(tab(target).layout.focused, incoming.focused);
    expect(container.read(workspaceProvider).tabs, hasLength(1));
    expect(container.read(terminalSessionsProvider), hasLength(4));
  });

  test('same-tab moves remove the leaf before inserting and never close the last source reference', () {
    final id = workspace.openLocal(_shell);
    workspace.split(SplitAxis.horizontal);
    workspace.split(SplitAxis.vertical);
    final original = tab(id).layout.leaves.toList();
    expect(
      workspace.moveTerminal(
        sourceTabId: id,
        sourcePaneId: original.last.pane,
        targetTabId: id,
        targetPaneId: original.first.pane,
        side: PaneSide.top,
      ),
      isTrue,
    );
    final moved = tab(id).layout;
    expect(moved.leaves.map((l) => l.pane), [original.last.pane, original.first.pane, original[1].pane]);
    expect(moved.focused, original.last.pane);
    expect(moved.leaves.map((l) => l.session).toSet(), original.map((l) => l.session).toSet());
    expect(container.read(workspaceProvider).tabs, hasLength(1));
    expect(container.read(terminalSessionsProvider), hasLength(3));
  });

  test('invalid, self-containing, overfull and stale moves publish and write nothing', () async {
    final source = workspace.openLocal(_shell);
    final sourceLayout = tab(source).layout;
    final target = workspace.openLocal(_shell);
    for (var i = 1; i < Layout.maxPanes; i++) {
      workspace.split(SplitAxis.horizontal);
    }
    final targetLayout = tab(target).layout;
    await workspace.saved;
    final before = container.read(workspaceProvider);
    final bytes = File('${dir.path}/workspace.json').readAsBytesSync();
    bool move(TabId sourceId, TabId targetId, PaneId pane, {Layout? expectedSource, Layout? expectedTarget}) =>
        workspace.moveTerminal(
          sourceTabId: sourceId,
          targetTabId: targetId,
          targetPaneId: pane,
          side: PaneSide.right,
          expectedSource: expectedSource,
          expectedTarget: expectedTarget,
        );
    expect(
      workspace.canMoveTerminal(
        sourceTabId: source,
        targetTabId: target,
        targetPaneId: targetLayout.focused,
        side: PaneSide.left,
      ),
      isFalse,
    );
    expect(move(source, target, targetLayout.focused), isFalse);
    expect(move(source, source, sourceLayout.focused), isFalse);
    expect(move(const TabId('missing'), target, targetLayout.focused), isFalse);
    expect(move(source, target, const PaneId('missing')), isFalse);
    expect(move(target, source, sourceLayout.focused, expectedSource: sourceLayout), isFalse);
    expect(
      workspace.moveTerminal(
        sourceTabId: source,
        sourcePaneId: sourceLayout.focused,
        targetTabId: source,
        targetPaneId: sourceLayout.focused,
        side: PaneSide.left,
      ),
      isFalse,
    );
    expect(identical(container.read(workspaceProvider), before), isTrue);
    expect(File('${dir.path}/workspace.json').readAsBytesSync(), bytes);

    workspace.focusPane(target, targetLayout.leaves.first.pane);
    final current = tab(target).layout;
    expect(move(target, source, sourceLayout.focused, expectedSource: targetLayout), isFalse);
    expect(
      workspace.moveTerminal(
        sourceTabId: target,
        sourcePaneId: current.focused,
        targetTabId: source,
        targetPaneId: sourceLayout.focused,
        side: PaneSide.bottom,
        expectedTarget: current,
      ),
      isFalse,
    );
  });

  test('moving the last pane removes only its empty tab and rejects a stale target layout', () {
    final source = workspace.openLocal(_shell);
    final sourceLayout = tab(source).layout;
    final target = workspace.openLocal(_shell);
    workspace.split(SplitAxis.vertical);
    final oldTarget = tab(target).layout;
    workspace.resize(target, const [], [1, 3]);
    final before = container.read(workspaceProvider);
    expect(
      workspace.moveTerminal(
        sourceTabId: source,
        sourcePaneId: sourceLayout.focused,
        targetTabId: target,
        targetPaneId: oldTarget.focused,
        side: PaneSide.right,
        expectedTarget: oldTarget,
      ),
      isFalse,
    );
    expect(identical(container.read(workspaceProvider), before), isTrue);
    expect(
      workspace.moveTerminal(
        sourceTabId: source,
        sourcePaneId: sourceLayout.focused,
        targetTabId: target,
        targetPaneId: oldTarget.focused,
        side: PaneSide.right,
        expectedSource: sourceLayout,
        expectedTarget: tab(target).layout,
      ),
      isTrue,
    );
    expect(container.read(workspaceProvider).tabs.map((t) => t.id), [target]);
    expect(container.read(terminalSessionsProvider), hasLength(3));
    expect(tab(target).layout.focusedLeaf.session, sourceLayout.focusedLeaf.session);
  });

  test('detach preserves source title, moves its existing pane, and single-pane detach only reorders', () {
    final source = workspace.openLocal(_shell);
    workspace.rename(source, 'group');
    workspace.split(SplitAxis.vertical);
    final old = tab(source).layout;
    final moved = old.focusedLeaf;
    final other = workspace.openLocal(_shell);
    final detached = workspace.detachPane(source, moved.pane, 1, expectedSource: old)!;
    expect(container.read(workspaceProvider).tabs.map((t) => t.id), [source, detached, other]);
    expect(tab(source).title, 'group');
    expect(tab(source).layout.leaves, hasLength(1));
    expect(tab(detached).title, isNull);
    expect(tab(detached).layout.focusedLeaf.session, moved.session);
    expect(tab(detached).layout.focused, moved.pane);
    expect(workspace.detachPane(source, moved.pane, 0, expectedSource: old), isNull);
    final same = workspace.detachPane(detached, moved.pane, 0);
    expect(same, detached);
    expect(container.read(workspaceProvider).tabs.map((t) => t.id), [detached, source, other]);
    expect(container.read(terminalSessionsProvider), hasLength(3));
  });

  test('moved layout persists and restores all targets without starting processes', () async {
    final source = workspace.openLocal(_shell);
    workspace.split(SplitAxis.vertical);
    final target = workspace.openLocal(_shell);
    expect(
      workspace.moveTerminal(
        sourceTabId: source,
        targetTabId: target,
        targetPaneId: tab(target).layout.focused,
        side: PaneSide.bottom,
      ),
      isTrue,
    );
    final panes = tab(target).layout.leaves.map((l) => l.pane).toList();
    final focus = tab(target).layout.focused;
    await workspace.saved;
    final restored = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), localPtyProvider.overrideWithValue(factory)],
    );
    try {
      final state = restored.read(workspaceProvider);
      await pumpEventQueue();
      expect(state.tabs, hasLength(1));
      expect(state.tabs.single.layout.leaves.map((l) => l.pane), panes);
      expect(state.tabs.single.layout.focused, focus);
      expect(
        restored
            .read(terminalSessionsProvider)
            .values
            .every((s) => !s.autoConnect && s.status == SessionStatus.idle && s.localShell == _shell),
        isTrue,
      );
      expect(factory.started, isEmpty);
      await restored.read(terminalSessionsProvider.notifier).shutdown();
    } finally {
      restored.dispose();
    }
  });

  test('layout capabilities use the typed move and detach handlers and stay unavailable to agents', () async {
    final source = workspace.openLocal(_shell), target = workspace.openLocal(_shell);
    final dispatcher = container.read(capabilityDispatcherProvider);
    final args = <String, Object?>{
      'sourceTabId': source.value,
      'targetTabId': target.value,
      'targetPaneId': tab(target).layout.focused.value,
      'side': 'left',
    };
    expect(dispatcher['workspace.moveTerminal']!.effect, Effect.localChange);
    final denied = await dispatcher.dispatch('workspace.moveTerminal', args, RequestContext(Origin.agent));
    expect((denied as Err).error.code, 'notExposed');
    final invalid = await dispatcher.dispatch('workspace.moveTerminal', {
      ...args,
      'side': 'middle',
    }, RequestContext(Origin.palette));
    expect((invalid as Err).error.code, 'invalidArgument');
    expect(
      await dispatcher.dispatch('workspace.moveTerminal', args, RequestContext(Origin.palette)),
      isA<Ok<Object?>>(),
    );
    final pane = tab(target).layout.leaves.first.pane;
    final detachArgs = <String, Object?>{'tabId': target.value, 'paneId': pane.value, 'index': 0};
    expect(
      await dispatcher.dispatch('workspace.detachPane', detachArgs, RequestContext(Origin.palette)),
      isA<Ok<Object?>>(),
    );
    final detachDenied = await dispatcher.dispatch('workspace.detachPane', detachArgs, RequestContext(Origin.agent));
    expect((detachDenied as Err).error.code, 'notExposed');
    expect(container.read(terminalSessionsProvider), hasLength(2));
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    expect(factory.started, isEmpty);
  });
}
