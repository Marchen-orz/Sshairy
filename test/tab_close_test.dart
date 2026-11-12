import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/capabilities/workspace.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/features/workspace/domain/layout.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-tab-close');
    File('${dir.path}/hosts.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'hosts': [
          {'id': 'h1', 'label': 'one', 'address': 'example.com', 'port': 22, 'username': 'u', 'auth': 'password'},
          {'id': 'h2', 'label': 'two', 'address': 'example.org', 'port': 22, 'username': 'u', 'auth': 'password'},
        ],
      }),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ProviderContainer create() => ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);

  /// Disk writes started by opening tabs must finish before the directory goes.
  Future<void> settle(ProviderContainer c) async {
    await c.read(hostsProvider.notifier).saved;
    await c.read(workspaceProvider.notifier).saved;
  }

  ProviderContainer container() {
    final c = create();
    addTearDown(() async {
      await settle(c);
      c.dispose();
    });
    return c;
  }

  /// Five tabs in order, the third split into two panes. Never connects: no pane is shown to dial.
  List<TabId> openTabs(ProviderContainer c) {
    final ws = c.read(workspaceProvider.notifier);
    final hosts = c.read(hostsProvider);
    final ids = [for (var i = 0; i < 5; i++) ws.openHost(hosts[i % 2])];
    ws.activate(ids[2]);
    expect(ws.split(SplitAxis.vertical), isTrue);
    return ids;
  }

  Set<SessionId> leaves(WorkspaceState state) => {
    for (final t in state.tabs)
      for (final l in t.layout.leaves) l.session,
  };

  group('which tabs a side closes', () {
    final tabs = [
      for (final id in ['a', 'b', 'c', 'd']) WorkspaceTab(TabId(id), Layout.single(PaneId(id), SessionId(id))),
    ];
    final state = WorkspaceState(tabs: tabs, active: tabs.first.id);

    List<String> ids(String of, TabCloseScope scope) => [
      for (final t in state.tabsToClose(TabId(of), scope)) t.id.value,
    ];

    test('left and right are the tabs on that side, others is both, in tab order', () {
      expect(ids('c', TabCloseScope.left), ['a', 'b']);
      expect(ids('b', TabCloseScope.right), ['c', 'd']);
      expect(ids('c', TabCloseScope.others), ['a', 'b', 'd']);
    });

    test('an empty side, a lone tab and a tab that is gone give nothing to close', () {
      expect(ids('a', TabCloseScope.left), isEmpty);
      expect(ids('d', TabCloseScope.right), isEmpty);
      expect(ids('gone', TabCloseScope.others), isEmpty);
      expect(WorkspaceState(tabs: tabs.sublist(0, 1)).tabsToClose(tabs.first.id, TabCloseScope.others), isEmpty);
    });
  });

  group('closing around the clicked tab', () {
    // Tabs 0..4; tab 2 has two panes. Active and the expected active are tab indexes, null is the host vault.
    for (final (scope, active, clicked, kept, expected) in <(TabCloseScope, int?, int, List<int>, int?)>[
      (TabCloseScope.left, 4, 2, [2, 3, 4], 4),
      (TabCloseScope.left, 0, 2, [2, 3, 4], 2),
      (TabCloseScope.left, 2, 2, [2, 3, 4], 2),
      (TabCloseScope.right, 0, 2, [0, 1, 2], 0),
      (TabCloseScope.right, 4, 2, [0, 1, 2], 2),
      (TabCloseScope.others, 4, 2, [2], 2),
      (TabCloseScope.others, 2, 2, [2], 2),
      (TabCloseScope.others, 1, 4, [4], 4),
      (TabCloseScope.others, null, 2, [2], null),
    ]) {
      test('${scope.name} of tab $clicked with ${active ?? 'the vault'} showing keeps $kept', () async {
        final c = container();
        final ids = openTabs(c);
        final ws = c.read(workspaceProvider.notifier);
        if (active == null) {
          ws.showVault();
        } else {
          ws.activate(ids[active]);
        }
        final before = c.read(workspaceProvider).tabs;
        var notified = 0;
        c.listen(workspaceProvider, (_, _) => notified++);

        expect(ws.closeTabs(ids[clicked], scope), 5 - kept.length);
        await Future<void>.delayed(Duration.zero);

        final state = c.read(workspaceProvider);
        expect(state.tabs.map((t) => t.id), [for (final i in kept) ids[i]]);
        for (final (n, i) in kept.indexed) {
          expect(state.tabs[n], same(before[i]), reason: 'a kept tab is not rebuilt');
        }
        expect(state.active, expected == null ? null : ids[expected]);
        expect(c.read(terminalSessionsProvider).keys.toSet(), leaves(state));
        expect(notified, 1, reason: 'one change for the whole batch');
      });
    }

    test('the host vault and the SFTP page stay up while tabs close behind them', () {
      final c = container();
      final ids = openTabs(c);
      final ws = c.read(workspaceProvider.notifier);
      ws.showFiles();
      expect(ws.closeTabs(ids[2], TabCloseScope.others), 4);
      final state = c.read(workspaceProvider);
      expect(state.active, isNull);
      expect(state.files, isTrue);
    });

    test('an empty side, a lone tab and a tab that is gone change nothing', () {
      final c = container();
      final ids = openTabs(c);
      final ws = c.read(workspaceProvider.notifier);
      final state = c.read(workspaceProvider);
      final sessions = c.read(terminalSessionsProvider);

      expect(ws.closeTabs(ids.first, TabCloseScope.left), 0);
      expect(ws.closeTabs(ids.last, TabCloseScope.right), 0);
      expect(ws.closeTabs(TabId('gone'), TabCloseScope.others), 0);
      expect(c.read(workspaceProvider), same(state));
      expect(c.read(terminalSessionsProvider), same(sessions));

      expect(ws.closeTabs(ids[2], TabCloseScope.others), 4);
      final lone = c.read(workspaceProvider);
      expect(ws.closeTabs(ids[2], TabCloseScope.others), 0);
      expect(c.read(workspaceProvider), same(lone));
    });

    test('the sessions of every closed tab are released and the kept ones stay alive', () {
      final c = container();
      final ids = openTabs(c);
      final ws = c.read(workspaceProvider.notifier);
      final sessions = {
        for (final t in c.read(workspaceProvider).tabs) t.id: [for (final l in t.layout.leaves) ws.session(l.session)!],
      };
      expect(sessions[ids[2]], hasLength(2));

      ws.closeTabs(ids[3], TabCloseScope.others);

      for (final MapEntry(key: tab, value: list) in sessions.entries) {
        for (final s in list) {
          // A closed session disposes its notifier, which then refuses listeners.
          if (tab == ids[3]) {
            expect(() => s.addListener(() {}), returnsNormally);
          } else {
            expect(() => s.addListener(() {}), throwsFlutterError);
          }
        }
      }
      expect(c.read(terminalSessionsProvider), hasLength(1));
    });

    test('what is left is what comes back after a restart, unconnected', () async {
      final first = create();
      final ids = openTabs(first);
      final ws = first.read(workspaceProvider.notifier);
      final hostOf = {
        for (final t in first.read(workspaceProvider).tabs) t.id: ws.session(t.layout.focusedLeaf.session)!.host.id,
      };
      ws.activate(ids[1]);
      expect(ws.closeTabs(ids[3], TabCloseScope.left), 3);
      await settle(first);
      first.dispose();

      final second = container();
      final state = second.read(workspaceProvider);
      expect(state.tabs, hasLength(2));
      expect(state.active, state.tabs.first.id, reason: 'the clicked tab took over from the closed active one');
      await Future<void>.delayed(Duration.zero);
      final sessions = second.read(terminalSessionsProvider);
      expect(sessions, hasLength(2));
      expect(state.tabs.map((t) => sessions[t.layout.focusedLeaf.session]!.host.id), [hostOf[ids[3]], hostOf[ids[4]]]);
      expect(sessions.values.every((s) => s.status == SessionStatus.idle && !s.autoConnect), isTrue);
    });
  });

  test('workspace.closeTabs serves the palette and the agent, and rejects bad input', () async {
    final c = container();
    final ids = openTabs(c);
    final dispatcher = CapabilityDispatcher(c.read(Provider((ref) => workspaceCapabilities(ref))));
    Future<Result<Object?>> call(Map<String, Object?> args, [Origin origin = Origin.palette]) =>
        dispatcher.dispatch('workspace.closeTabs', args, RequestContext(origin));
    String code(Result<Object?> r) => (r as Err<Object?>).error.code;
    final clicked = ids[2].value;

    expect(code(await call({'tabId': clicked, 'scope': 'right'}, Origin.agent)), 'unauthorized');
    expect(code(await call({'tabId': 'gone', 'scope': 'right'})), 'notFound');
    expect(code(await call({'tabId': clicked, 'scope': 'up'})), 'invalidArgument');
    expect(c.read(workspaceProvider).tabs, hasLength(5), reason: 'rejected calls change nothing');

    expect(((await call({'tabId': clicked, 'scope': 'right'})) as Ok<Object?>).value, {'closed': 2});
    expect(c.read(workspaceProvider).tabs.map((t) => t.id), [ids[0], ids[1], ids[2]]);
    expect(((await call({'tabId': clicked, 'scope': 'right'})) as Ok<Object?>).value, {'closed': 0});
    expect(((await call({'tabId': clicked, 'scope': 'others'}, Origin.ui)) as Ok<Object?>).value, {'closed': 2});
    expect(c.read(workspaceProvider).tabs.map((t) => t.id), [ids[2]]);
  });
}
