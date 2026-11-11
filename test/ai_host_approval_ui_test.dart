import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/providers.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/ai/presentation/host_approval.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

final _profile = ModelProfile(protocol: ModelProtocol.openai, endpoint: 'https://model.invalid/v1', model: 'test');

class _Configuration extends AiConfigurationController {
  @override
  AiConfiguration build() => AiConfiguration(enabled: true, profile: _profile);
}

class _Backend implements AgentBackend {
  @override
  List<AgentHost> get hosts => const [];
  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) => throw StateError('no UI connection');
}

class _Model implements ModelProvider {
  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) => throw StateError('no UI request');
  @override
  void close() {}
}

class _Journal implements OperationJournal {
  @override
  Future<List<OperationRecord>> load() async => const [];
  @override
  Future<void> record(OperationRecord record) async {}
  @override
  Future<void> get saved async {}
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

  AgentHostApproval? pending;
  final decisions = <(AgentHostApproval, bool)>[];
  @override
  AgentHostApproval? get hostApproval => pending;
  void request(AgentHostApproval approval) {
    pending = approval;
    notifyListeners();
  }

  @override
  void decideHost(AgentHostApproval expected, bool allowed) {
    if (!identical(expected, pending)) return;
    decisions.add((expected, allowed));
    pending = null;
    notifyListeners();
  }

  @override
  void stop() {
    pending = null;
    notifyListeners();
  }
}

void main() {
  Future<_Runtime> mount(WidgetTester tester) async {
    final runtime = _Runtime();
    final container = ProviderContainer(
      overrides: [
        agentRuntimeProvider.overrideWithValue(runtime),
        aiConfigurationProvider.overrideWith(_Configuration.new),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      container.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AgentHostApprovalPrompts(child: Scaffold(body: Text('Workspace'))),
        ),
      ),
    );
    return runtime;
  }

  testWidgets('host confirmation works with no mounted Agent sidebar', (tester) async {
    final runtime = await mount(tester);
    final approval = AgentHostApproval(const HostId('database'), 'Database', 'conversation');
    runtime.request(approval);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-host-approval')), findsOneWidget);
    expect(find.textContaining('Database'), findsOneWidget);
    expect(runtime.decisions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-host-allow')));
    await tester.pumpAndSettle();
    expect(runtime.decisions.single, (approval, true));
    expect(find.byKey(const ValueKey('ai-host-approval')), findsNothing);
  });

  testWidgets('dismissing a host confirmation denies access', (tester) async {
    final runtime = await mount(tester);
    final approval = AgentHostApproval(const HostId('database'), 'Database', 'conversation');
    runtime.request(approval);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(runtime.decisions.single, (approval, false));
  });

  testWidgets('Stop removes the pending host modal without approving it', (tester) async {
    final runtime = await mount(tester);
    runtime.request(AgentHostApproval(const HostId('database'), 'Database', 'conversation'));
    await tester.pumpAndSettle();
    runtime.stop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-host-approval')), findsNothing);
    expect(runtime.decisions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale modal cannot decide a replacement host request', (tester) async {
    final runtime = await mount(tester);
    runtime.request(AgentHostApproval(const HostId('a'), 'Host A', 'conversation'));
    await tester.pumpAndSettle();
    final next = AgentHostApproval(const HostId('b'), 'Host B', 'conversation');
    runtime.request(next);
    await tester.pumpAndSettle();
    expect(find.textContaining('Host A'), findsNothing);
    expect(find.textContaining('Host B'), findsOneWidget);
    expect(runtime.decisions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-host-allow')));
    await tester.pumpAndSettle();
    expect(runtime.decisions.single, (next, true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the presenter closes and denies its pending modal', (tester) async {
    final runtime = await mount(tester);
    runtime.request(AgentHostApproval(const HostId('database'), 'Database', 'conversation'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(runtime.decisions.single.$2, isFalse);
    expect(tester.takeException(), isNull);
  });
}
