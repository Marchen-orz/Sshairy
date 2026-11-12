import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/ai_resources.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/features/forwarding/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/ids.dart';

const _a = Host(id: HostId('a'), label: 'A', address: 'a.invalid', username: 'u');
const _b = Host(id: HostId('b'), label: 'B', address: 'b.invalid', username: 'u');

class _NoPty implements LocalPtyFactory {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('No local process may start');
}

void main() {
  late ConnectionManager manager;
  late TerminalSession a, b, local;
  late WorkspaceState state;
  late List<ForwardState> forwards;
  late List<Transfer> transfers;
  late Map<ForwardId, Object> forwardAttempts;
  late Map<TransferId, Object> transferAttempts;
  late AppAgentResources resources;
  var hostRevision = 0;

  setUp(() {
    manager = ConnectionManager((_, _, _) async => throw StateError('No connection may start'));
    a = TerminalSession(const SessionId('a'), _a, manager, autoConnect: false);
    b = TerminalSession(const SessionId('b'), _b, manager, autoConnect: false);
    local = TerminalSession.local(
      const SessionId('local'),
      const LocalShell(kind: LocalShellKind.cmd, executable: r'C:\Windows\System32\cmd.exe'),
      _NoPty(),
      autoConnect: false,
    );
    state = WorkspaceState(
      tabs: [
        WorkspaceTab(const TabId('a'), Layout.single(const PaneId('pa'), a.id)),
        WorkspaceTab(const TabId('b'), Layout.single(const PaneId('pb'), b.id)),
        WorkspaceTab(const TabId('local'), Layout.single(const PaneId('pl'), local.id)),
      ],
      active: const TabId('a'),
    );
    forwards = [];
    transfers = [];
    forwardAttempts = {};
    transferAttempts = {};
    hostRevision = 0;
    resources = AppAgentResources(
      workspace: () => state,
      sessions: () => {a.id: a, b.id: b, local.id: local},
      forwards: () => forwards,
      forwardBinding: (id) => forwardAttempts[id] ?? forwards.where((s) => s.rule.id == id).firstOrNull?.rule,
      transfers: () => transfers,
      transferBinding: (id) => transferAttempts[id] ?? transfers.where((t) => t.id == id).firstOrNull,
      hosts: () => const [_a, _b],
      hostRevision: () => hostRevision,
    );
  });

  tearDown(() {
    a.close();
    b.close();
    local.close();
    manager.closeAll();
  });

  test('implicit close binds the actual focused tab and pane', () {
    final before = resources.resolve('session.close', {})!;
    expect(before.hosts, [_a.id]);
    expect(before.details['tabId'], 'a');
    state = WorkspaceState(tabs: state.tabs, active: const TabId('b'));
    final after = resources.resolve('session.close', {})!;
    expect(after.hosts, [_b.id]);
    expect(after.binding, isNot(before.binding));

    state = WorkspaceState(
      tabs: [
        state.tabs.first.withLayout(
          state.tabs.first.layout.split(const PaneId('pa'), SplitAxis.horizontal, const PaneId('pb'), b.id)!,
        ),
        state.tabs.last,
      ],
      active: const TabId('a'),
    );
    final split = resources.resolve('session.close', {})!;
    expect(split.hosts, [_b.id]);
    state = WorkspaceState(
      tabs: [state.tabs.first.withLayout(state.tabs.first.layout.focus(const PaneId('pa'))), state.tabs.last],
      active: state.active,
    );
    expect(resources.resolve('session.close', {})!.binding, isNot(split.binding));
  });

  test('close tabs binds every affected host and the tab order', () {
    final args = <String, Object?>{'tabId': 'a', 'scope': 'right'};
    final before = resources.resolve('workspace.closeTabs', args)!;
    expect(before.hosts, [_b.id]);
    expect(before.details['tabIds'], ['b', 'local']);
    state = WorkspaceState(tabs: [state.tabs[1], state.tabs[0], state.tabs[2]], active: state.active);
    final after = resources.resolve('workspace.closeTabs', args)!;
    expect(after.hosts, isEmpty);
    expect(after.details['tabIds'], ['local']);
    expect(after.binding, isNot(before.binding));
  });

  test('layout identity and session generation invalidate an approval even after returning to its old values', () {
    final args = <String, Object?>{'tabId': 'a'};
    final before = resources.resolve('workspace.renameTab', args)!;
    final old = state.tabs.first;
    state = WorkspaceState(
      tabs: [old.withLayout(Layout.single(const PaneId('pa'), a.id)), ...state.tabs.skip(1)],
      active: state.active,
    );
    expect(resources.resolve('workspace.renameTab', args)!.binding, isNot(before.binding));
    final generation = resources.resolve('workspace.renameTab', args)!.binding;
    a.status = SessionStatus.failed;
    expect(resources.resolve('workspace.renameTab', args)!.binding, isNot(generation));
  });

  test('Agent cannot split or reconnect a local terminal', () {
    for (final capability in ['workspace.split', 'session.reconnect']) {
      expect(resources.resolve(capability, {'tabId': 'local'}), isNull);
      expect(resources.resolve(capability, {'tabId': 'b'})!.hosts, [_b.id]);
    }
  });

  test('forward approval includes the actual endpoints and listener attempt', () {
    const rule = ForwardRule(id: ForwardId('f'), hostId: HostId('b'), listenPort: 23001, destinationPort: 22);
    forwards = [const ForwardState(rule, phase: ForwardPhase.running, port: 23001)];
    forwardAttempts[rule.id] = Object();
    final before = resources.resolve('forward.stop', {'id': 'f'})!;
    expect(before.hosts, [_b.id]);
    expect(before.details['rule'], rule.toJson());
    expect(resources.resolve('forward.start', {'id': 'f', 'hostId': 'a'}), isNull);
    forwardAttempts[rule.id] = Object();
    expect(resources.resolve('forward.stop', {'id': 'f'})!.binding, isNot(before.binding));
    forwards = [ForwardState(ForwardRule(id: rule.id, hostId: rule.hostId, listenPort: 23001, destinationPort: 443))];
    expect(resources.resolve('forward.stop', {'id': 'f'})!.binding, isNot(before.binding));
  });

  test('transfer cancellation binds both remote endpoints and attempt without progress noise', () {
    final transfer = Transfer(
      id: const TransferId('t'),
      batch: 'batch',
      source: const FileEnd(HostId('a'), '/owned/source'),
      target: const FileEnd(HostId('b'), '/owned/target'),
      created: DateTime.utc(2026, 11, 12),
      state: TransferState.running,
    );
    transfers = [transfer];
    transferAttempts[transfer.id] = Object();
    final before = resources.resolve('transfer.cancel', {'transferId': 't'})!;
    expect(before.hosts, [_a.id, _b.id]);
    expect(jsonEncode(before.details), contains('/owned/source'));
    transfers = [transfer.copyWith(bytes: 512)];
    expect(resources.resolve('transfer.cancel', {'transferId': 't'})!.binding, before.binding);
    transferAttempts[transfer.id] = Object();
    expect(resources.resolve('transfer.cancel', {'transferId': 't'})!.binding, isNot(before.binding));
    transfers = [
      Transfer(
        id: transfer.id,
        batch: 'local',
        source: const FileEnd(null, '/private'),
        target: transfer.target,
        created: transfer.created,
      ),
    ];
    expect(resources.resolve('transfer.cancel', {'transferId': 't'}), isNull);
  });

  test('host metadata revision is checked while an update approval is pending', () {
    final before = resources.resolve('host.update', {'hostId': 'a'})!;
    hostRevision++;
    expect(resources.resolve('host.update', {'hostId': 'a'})!.binding, isNot(before.binding));
    expect(
      resources.resolve('host.move', {
        'hostIds': ['a', 'b'],
      })!.hosts,
      [_a.id, _b.id],
    );
    expect(resources.resolve('host.delete', {'hostId': 'missing'}), isNull);
  });
}
