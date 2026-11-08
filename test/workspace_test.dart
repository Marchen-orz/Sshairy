import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/data_dir.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-ws');
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

  ProviderContainer container() => ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);

  Map<String, Object?> leaf(String pane, String session) => {'type': 'leaf', 'pane': pane, 'session': session};

  test('restores saved tabs unconnected, with the active one in front', () async {
    File('${dir.path}/workspace.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'tabs': [
          {
            'layout': {'root': leaf('p', 's'), 'focused': 'p'},
            'hosts': {'s': 'h1'},
          },
          {
            'layout': {
              'root': {
                'type': 'split',
                'axis': 'horizontal',
                'children': [leaf('a', 'sa'), leaf('b', 'sb')],
                'ratios': [0.5, 0.5],
              },
              'focused': 'b',
            },
            'hosts': {'sa': 'h1', 'sb': 'h2'},
          },
          {
            'layout': {'root': leaf('g', 'sg'), 'focused': 'g'},
            'hosts': {'sg': 'deleted'},
          },
        ],
        'active': 1,
      }),
    );
    final c = container();
    addTearDown(c.dispose);
    final state = c.read(workspaceProvider);
    addTearDown(() => c.read(workspaceProvider.notifier).saved);
    expect(state.tabs, hasLength(2), reason: 'the tab of a deleted host is dropped');
    expect(state.active, state.tabs[1].id);
    await Future<void>.delayed(Duration.zero);
    final sessions = c.read(terminalSessionsProvider);
    final restored = [for (final l in state.tabs[1].layout.leaves) sessions[l.session]!];
    expect(restored.map((s) => s.host.label), ['one', 'two']);
    expect(restored.every((s) => s.status == SessionStatus.idle && !s.autoConnect), isTrue);
  });

  test('a split tab survives a restart, and the vault stays in front when it was', () async {
    final first = container();
    final host = first.read(hostsProvider).firstWhere((h) => h.label == 'two');
    final ws = first.read(workspaceProvider.notifier);
    ws.openHost(host);
    expect(ws.split(SplitAxis.vertical), isTrue);
    ws.showVault();
    await ws.saved;
    first.dispose();

    final second = container();
    addTearDown(() async {
      await second.read(hostsProvider.notifier).saved;
      await second.read(workspaceProvider.notifier).saved;
      second.dispose();
    });
    final state = second.read(workspaceProvider);
    expect(state.active, isNull);
    expect(state.tabs.single.layout.leaves, hasLength(2));
    await Future<void>.delayed(Duration.zero);
    final sessions = second.read(terminalSessionsProvider);
    expect(state.tabs.single.layout.leaves.map((l) => sessions[l.session]!.host.label), ['two', 'two']);
  });

  test('a renamed tab keeps its name across a restart; a blank name goes back to the host', () async {
    final first = container();
    final host = first.read(hostsProvider).firstWhere((h) => h.label == 'one');
    final ws = first.read(workspaceProvider.notifier);
    ws.openHost(host);
    final id = first.read(workspaceProvider).tabs.single.id;
    ws.rename(id, '  prod  ');
    final copy = ws.duplicate(id);
    expect(copy, isNotNull);
    final tabs = first.read(workspaceProvider).tabs;
    expect(tabs.map((t) => t.title), ['prod', null]);
    expect(first.read(workspaceProvider).active, copy);
    final sessions = first.read(terminalSessionsProvider);
    expect(sessions[tabs[1].layout.focusedLeaf.session]!.host.id, host.id);
    await ws.saved;
    first.dispose();

    final second = container();
    addTearDown(() async {
      await second.read(hostsProvider.notifier).saved;
      await second.read(workspaceProvider.notifier).saved;
      second.dispose();
    });
    final restored = second.read(workspaceProvider).tabs;
    expect(restored.first.title, 'prod');
    final ws2 = second.read(workspaceProvider.notifier);
    addTearDown(() => ws2.saved);
    ws2.rename(restored.first.id, ' ');
    expect(second.read(workspaceProvider).tabs.first.title, isNull);
    await Future<void>.delayed(Duration.zero);
  });
}
