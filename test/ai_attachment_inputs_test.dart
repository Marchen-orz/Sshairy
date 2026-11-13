import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/ai/adapters/attachment_drop.dart';
import 'package:sshairy/features/ai/adapters/attachments.dart';
import 'package:sshairy/features/ai/application/composer.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/conversations.dart';
import 'package:sshairy/features/ai/application/providers.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/ai/presentation/agent_panel.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

final _profile = ModelProfile(protocol: ModelProtocol.openai, endpoint: 'https://model.invalid/v1', model: 'test');

class _Configuration extends AiConfigurationController {
  @override
  AiConfiguration build() => AiConfiguration(enabled: true, profile: _profile);

  void setEnabled(bool enabled) =>
      state = AiConfiguration(enabled: enabled, profile: _profile, revision: state.revision + 1);
}

class _Settings extends SettingsNotifier {
  @override
  Settings build() => const Settings();
}

class _Backend implements AgentBackend {
  @override
  List<AgentHost> get hosts => const [];
  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) => throw StateError('No SSH in attachment tests');
}

class _Journal implements OperationJournal {
  @override
  Future<List<OperationRecord>> load() async => const [];
  @override
  Future<void> record(OperationRecord record) async {}
  @override
  Future<void> get saved async {}
}

class _Model implements ModelProvider {
  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) =>
      throw StateError('No HTTP in widget tests');
  @override
  void close() {}
}

class _Runtime extends AgentRuntime {
  _Runtime()
    : super(
        model: _Model(),
        backend: _Backend(),
        journal: _Journal(),
        dispatcher: CapabilityDispatcher(const []),
        configuration: () => (enabled: true, profile: _profile, revision: 0),
      );
  bool active = false;
  @override
  bool get busy => active;
  void setBusy(bool value) {
    active = value;
    notifyListeners();
  }
}

class _Store implements ConversationStore {
  @override
  Future<List<AgentConversationRecord>> load() async => const [];
  @override
  Future<void> save(List<AgentConversationRecord> records) async {}
  @override
  Future<void> get saved async {}
}

/// The fake system clipboard text; the real one is never touched.
String? _clipboardText;

Future<ProviderContainer> _panel(WidgetTester tester, AgentAttachmentPicker picker) async {
  _clipboardText = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData' && _clipboardText != null ? {'text': _clipboardText} : null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  tester.view.physicalSize = const Size(440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final runtime = _Runtime();
  final container = ProviderContainer(
    overrides: [
      aiConfigurationProvider.overrideWith(_Configuration.new),
      settingsProvider.overrideWith(_Settings.new),
      agentBackendProvider.overrideWithValue(_Backend()),
      agentRuntimeProvider.overrideWithValue(runtime),
      agentConversationStoreProvider.overrideWithValue(_Store()),
      agentConversationRoutesProvider.overrideWithValue(() => const {}),
      agentAttachmentPickerProvider.overrideWithValue(picker),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    runtime.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light).copyWith(splashFactory: NoSplash.splashFactory),
        home: const Scaffold(body: AgentPanel()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return container;
}

Future<File> _file(WidgetTester tester, {String name = 'notes.txt', String content = 'attached content 中文'}) async {
  final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('sshairy-attachment-input-')))!;
  addTearDown(() => tester.runAsync(() => directory.delete(recursive: true)));
  final file = File('${directory.path}/$name');
  await tester.runAsync(() => file.writeAsString(content));
  return file;
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (done()) return;
  }
  fail('Attachment UI did not settle');
}

Future<void> _paste(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ai-agent-goal')));
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

AgentAttachmentDropZone _drop(WidgetTester tester) =>
    tester.widget<AgentAttachmentDropZone>(find.byKey(const ValueKey('ai-agent-file-drop')));

void main() {
  testWidgets('file paste and drop import previewable attachments while preserving the draft', (tester) async {
    final file = await _file(tester);
    final container = await _panel(tester, AgentAttachmentPicker(clipboard: () async => [file.path]));
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'keep this draft');
    await _paste(tester);
    await _until(tester, () => container.read(agentComposerProvider).attachments.length == 1);
    expect(container.read(agentComposerProvider).goal, 'keep this draft');
    expect(container.read(agentComposerProvider).attachments.single.name, 'notes.txt');
    final preview = find.byKey(
      ValueKey('ai-attachment-preview-${container.read(agentComposerProvider).attachments.single.id}'),
    );
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.text('attached content 中文'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    _drop(tester).onDrop([file.path]);
    await _until(tester, () => container.read(agentComposerProvider).attachments.length == 2);
    expect(
      container.read(agentComposerProvider).attachments.map((a) => a.content),
      everyElement('attached content 中文'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pasting six log files no longer hits the four-file or 64 KiB limits', (tester) async {
    final file = await _file(tester, name: 'service.output', content: 'log line\n' * 10000);
    final container = await _panel(tester, AgentAttachmentPicker(clipboard: () async => List.filled(6, file.path)));
    await _paste(tester);
    await _until(tester, () => container.read(agentComposerProvider).attachments.length == 6);
    expect(container.read(agentComposerProvider).attachments.every((item) => item.bytes > 65536), isTrue);
    expect(find.textContaining('64 KiB'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain text paste including a path uses the normal text editor', (tester) async {
    var clipboardReads = 0;
    final container = await _panel(
      tester,
      AgentAttachmentPicker(
        clipboard: () async {
          clipboardReads++;
          return [];
        },
      ),
    );
    const text = r'C:\a-plain-text-path\notes.txt';
    _clipboardText = text;
    await _paste(tester);
    await _until(tester, () => container.read(agentComposerProvider).goal == text);
    expect(clipboardReads, 1);
    expect(container.read(agentComposerProvider).attachments, isEmpty);
  });

  testWidgets('the text selection paste action also accepts file-only clipboard contents', (tester) async {
    final file = await _file(tester);
    final container = await _panel(tester, AgentAttachmentPicker(clipboard: () async => [file.path]));
    await tester.tap(find.byKey(const ValueKey('ai-agent-goal')));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal')));
    final editable = tester.state<EditableTextState>(find.byType(EditableText).first);
    final menu = field.contextMenuBuilder!(
      tester.element(find.byKey(const ValueKey('ai-agent-goal'))),
      editable,
    ) as AdaptiveTextSelectionToolbar;
    menu.buttonItems!.singleWhere((item) => item.type == ContextMenuButtonType.paste).onPressed!();
    await _until(tester, () => container.read(agentComposerProvider).attachments.isNotEmpty);
    expect(container.read(agentComposerProvider).attachments.single.name, 'notes.txt');
  });

  testWidgets('unsupported drop keeps existing attachments and shows a local error', (tester) async {
    final file = await _file(tester, name: 'unsupported.pdf');
    final container = await _panel(tester, AgentAttachmentPicker());
    final existing = AgentAttachment.text(id: 'existing', name: 'existing.txt', text: 'preserved');
    container.read(agentComposerProvider.notifier).setAttachments([existing]);
    await tester.pump();
    _drop(tester).onDrop([file.path]);
    final l = AppLocalizations.of(tester.element(find.byType(AgentPanel)));
    await _until(
      tester,
      () => find
          .text(l.aiAgentAttachmentFileError('unsupported.pdf', l.aiAgentAttachmentUnsupported))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining(file.parent.path), findsNothing);
    expect(container.read(agentComposerProvider).attachments.single, same(existing));
  });

  testWidgets('disabled and running agents refuse file imports', (tester) async {
    final file = await _file(tester);
    var reads = 0;
    final container = await _panel(
      tester,
      AgentAttachmentPicker(
        clipboard: () async {
          reads++;
          return [file.path];
        },
      ),
    );
    final runtime = container.read(agentRuntimeProvider) as _Runtime;
    runtime.setBusy(true);
    await tester.pump();
    expect(_drop(tester).enabled, isFalse);
    _drop(tester).onDrop([file.path]);
    await _paste(tester);
    expect(container.read(agentComposerProvider).attachments, isEmpty);
    expect(reads, 0);
    runtime.setBusy(false);
    (container.read(aiConfigurationProvider.notifier) as _Configuration).setEnabled(false);
    await tester.pump();
    expect(_drop(tester).enabled, isFalse);
    _drop(tester).onDrop([file.path]);
    await tester.pump();
    expect(container.read(agentComposerProvider).attachments, isEmpty);
  });

  for (final change in ['conversation', 'disable', 'busy', 'attachments']) {
    testWidgets('late file paste is discarded after changing $change', (tester) async {
      final file = await _file(tester);
      final gate = Completer<List<String>>();
      final container = await _panel(tester, AgentAttachmentPicker(clipboard: () => gate.future));
      await _paste(tester);
      switch (change) {
        case 'conversation':
          container.read(agentConversationsProvider).newConversation();
        case 'disable':
          (container.read(aiConfigurationProvider.notifier) as _Configuration).setEnabled(false);
        case 'busy':
          (container.read(agentRuntimeProvider) as _Runtime).setBusy(true);
        case 'attachments':
          container.read(agentComposerProvider.notifier).setAttachments([
            AgentAttachment.text(id: 'new', name: 'new.txt', text: 'other attachment'),
          ]);
      }
      gate.complete([file.path]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(agentComposerProvider).attachments.map((a) => a.name), isNot(contains('notes.txt')));
      (container.read(agentRuntimeProvider) as _Runtime).setBusy(false);
      expect(tester.takeException(), isNull);
    });
  }
}
