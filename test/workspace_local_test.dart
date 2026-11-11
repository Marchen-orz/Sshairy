import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/dock_panel.dart';
import 'package:sshairy/design/popup.dart';
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/monitor/api.dart';
import 'package:sshairy/features/files/api.dart' show SideFilesPanel;
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/l10n/app_localizations.dart';

const _shell = LocalShell(kind: LocalShellKind.cmd, executable: r'C:\Windows\System32\cmd.exe');

class _Hosts extends HostsNotifier {
  @override
  List<Host> build() => const [Host(id: HostId('h'), label: 'remote', address: 'example.com', username: 'u')];
}

class _AiConfiguration extends AiConfigurationController {
  @override
  AiConfiguration build() => AiConfiguration(
    enabled: true,
    profile: ModelProfile(protocol: ModelProtocol.openai, endpoint: 'https://model.example/v1', model: 'example'),
  );
}

class _Pty implements LocalPty {
  final bytes = StreamController<Uint8List>();
  final exited = Completer<int>();
  @override
  Stream<Uint8List> get output => bytes.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (exited.isCompleted) return;
    bytes.close();
    exited.complete(0);
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

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

void main() {
  testWidgets('plus opens discovered shells, with no duplicate host navigation or remote panels', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-local-ui-');
    final factory = _Factory();
    var dials = 0;
    final manager = ConnectionManager((_, _, _) async {
      dials++;
      throw const ConnectError(ConnectFailure.auth);
    });
    final container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        hostsProvider.overrideWith(_Hosts.new),
        aiConfigurationProvider.overrideWith(_AiConfiguration.new),
        localShellsProvider.overrideWithValue(const [_shell]),
        localPtyProvider.overrideWithValue(factory),
        connectionManagerProvider.overrideWithValue(manager),
      ],
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var flushed = false;
      final pending = Future.wait([
        container.read(workspaceProvider.notifier).saved,
        container.read(terminalSessionsProvider.notifier).shutdown(),
      ]).then((_) => flushed = true);
      for (var i = 0; i < 400 && !flushed; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(flushed, isTrue);
      await pending;
      container.dispose();
      manager.closeAll();
      await tester.runAsync(() => dir.delete(recursive: true));
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _Assets(),
          child: MaterialApp(
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New connection'));
    await tester.pumpAndSettle();
    final popup = find.byType(PopupSurface);
    expect(find.descendant(of: popup, matching: find.text('CMD')), findsOneWidget);
    expect(find.descendant(of: popup, matching: find.text('Hosts')), findsNothing);
    expect(find.descendant(of: popup, matching: find.text('remote')), findsOneWidget);
    await tester.tap(find.descendant(of: popup, matching: find.text('CMD')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(factory.started, hasLength(1));
    expect(container.read(workspaceProvider.notifier).focusedSession?.isLocal, isTrue);
    expect(find.text('CMD'), findsOneWidget);
    expect(find.byType(MonitorPanel), findsNothing);
    expect(find.byType(SideFilesPanel), findsNothing);
    expect(find.byTooltip('Server monitor'), findsNothing);
    expect(find.byTooltip('Files'), findsNothing);
    expect(dials, 0);
    expect(tester.takeException(), isNull);

    Future<void> agentShortcut(LogicalKeyboardKey modifier) async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    await agentShortcut(LogicalKeyboardKey.controlLeft);
    expect(find.byType(AgentPanel), findsOneWidget);
    final agentDock = find.ancestor(of: find.byType(AgentPanel), matching: find.byType(DockPanel)).first;
    expect(tester.widget<DockPanel>(agentDock).showHeader, isFalse);
    expect(find.descendant(of: find.byType(AgentPanel), matching: find.text('Airy')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Keep this draft');
    await tester.pump();
    await agentShortcut(LogicalKeyboardKey.controlLeft);
    expect(find.byType(AgentPanel), findsNothing);
    await agentShortcut(LogicalKeyboardKey.metaLeft);
    expect(find.byType(AgentPanel), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal'))).controller!.text, 'Keep this draft');
    await agentShortcut(LogicalKeyboardKey.metaLeft);
    expect(find.byType(AgentPanel), findsNothing);
    final terminal = tester.widget<TerminalPane>(find.byType(TerminalPane));
    terminal.onAskAgent!('Investigate service health');
    await tester.pumpAndSettle();
    expect(find.byType(AgentPanel), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal'))).controller!.text,
      'Keep this draft\nInvestigate service health',
    );
    expect(container.read(agentComposerProvider).host, isNull);
    expect(container.read(agentRuntimeProvider).busy, isFalse);
    expect(dials, 0);

    final dispatcher = container.read(capabilityDispatcherProvider);
    final invalid = await dispatcher.dispatch('session.openLocal', {
      'executable': r'C:\unknown.exe',
    }, RequestContext(Origin.palette));
    expect(invalid, isA<Err<Object?>>());
    expect((invalid as Err<Object?>).error.code, 'notFound');
    final denied = await dispatcher.dispatch('session.openLocal', {
      'executable': _shell.executable,
    }, RequestContext(Origin.agent));
    expect((denied as Err<Object?>).error.code, 'notExposed');
    final opened = await dispatcher.dispatch('session.openLocal', {
      'executable': _shell.executable,
    }, RequestContext(Origin.palette));
    expect(opened, isA<Ok<Object?>>());
    await tester.pump();
    expect(container.read(workspaceProvider).tabs, hasLength(2));
    expect(container.read(agentFocusedHostProvider), isNull);
    final workspace = container.read(workspaceProvider.notifier);
    final localTab = container.read(workspaceProvider).active!;
    final remoteTab = workspace.openHost(container.read(hostsProvider).single);
    expect(container.read(agentFocusedHostProvider), const HostId('h'));
    workspace.showVault();
    expect(container.read(agentFocusedHostProvider), isNull);
    workspace.activate(remoteTab);
    expect(container.read(agentFocusedHostProvider), const HostId('h'));
    workspace.activate(localTab);
    expect(container.read(agentFocusedHostProvider), isNull);
  });
}
