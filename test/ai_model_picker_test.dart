import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/ai/application/model_catalog.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/ai/domain/model_catalog.dart';
import 'package:sshairy/features/ai/presentation/model_picker.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Catalog implements ModelCatalog {
  int calls = 0;
  bool fail = false;
  Completer<List<String>>? pending;
  final cancels = <CancellationToken>[];

  @override
  Future<List<String>> list({
    required ModelProtocol protocol,
    required String endpoint,
    required CancellationToken cancel,
    String? credentialIdentity,
    Secret? draftKey,
  }) async {
    calls++;
    cancels.add(cancel);
    if (fail) throw const ModelFailure('modelCatalogFailed');
    return pending?.future ?? ['alpha-model', 'Beta-model', 'other-model'];
  }

  @override
  void cancelAll() {
    for (final cancel in cancels) {
      cancel.cancel();
    }
  }

  @override
  void close() => cancelAll();
}

Widget _app(_Catalog catalog, Widget child, {double scale = 1}) => ProviderScope(
  overrides: [aiModelCatalogProvider.overrideWithValue(catalog)],
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(Space.md), child: child),
    ),
  ),
);

void main() {
  testWidgets('picker fetches only after opening and searches fetched IDs without new requests', (tester) async {
    final catalog = _Catalog();
    String? selected;
    await tester.pumpWidget(
      _app(
        catalog,
        AiModelPicker(
          value: 'alpha-model',
          protocol: ModelProtocol.openai,
          endpoint: 'https://model.example/v1',
          onChanged: (value) => selected = value,
        ),
      ),
    );
    expect(catalog.calls, 0);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(catalog.calls, 1);
    expect(find.byKey(const ValueKey('ai-model-option-alpha-model')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ai-model-search')), 'BETA');
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-model-option-alpha-model')), findsNothing);
    expect(find.byKey(const ValueKey('ai-model-option-Beta-model')), findsOneWidget);
    expect(catalog.calls, 1);
    await tester.tap(find.byKey(const ValueKey('ai-model-option-Beta-model')));
    await tester.pumpAndSettle();
    expect(selected, 'Beta-model');
    expect(catalog.cancels.single.isCancelled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed catalog keeps selection and permits retry or a custom model ID', (tester) async {
    final catalog = _Catalog()..fail = true;
    String? selected;
    await tester.pumpWidget(
      _app(
        catalog,
        AiModelPicker(
          value: 'saved-model',
          protocol: ModelProtocol.openai,
          endpoint: 'https://model.example/v1',
          onChanged: (value) => selected = value,
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-model-option-saved-model')), findsOneWidget);
    expect(find.textContaining('Could not load models'), findsOneWidget);
    catalog.fail = false;
    await tester.tap(find.byTooltip('Refresh models'));
    await tester.pumpAndSettle();
    expect(catalog.calls, 2);
    expect(find.byKey(const ValueKey('ai-model-option-alpha-model')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ai-model-search')), 'custom/model');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-model-option-custom/model')));
    await tester.pumpAndSettle();
    expect(selected, 'custom/model');
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing destination cancels the open request and cannot select its late result', (tester) async {
    final catalog = _Catalog()..pending = Completer<List<String>>();
    var endpoint = 'https://old.example/v1';
    String? selected;
    late StateSetter update;
    await tester.pumpWidget(
      _app(
        catalog,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AiModelPicker(
              value: 'selected',
              protocol: ModelProtocol.openai,
              endpoint: endpoint,
              onChanged: (value) => selected = value,
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump();
    expect(catalog.calls, 1);
    update(() => endpoint = 'https://new.example/v1');
    await tester.pump();
    expect(catalog.cancels.single.isCancelled, isTrue);
    catalog.pending!.complete(['late-model']);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-model-option-late-model')), findsNothing);
    expect(selected, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact model popup remains bounded in a short scaled window', (tester) async {
    tester.view.physicalSize = const Size(300, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _Catalog();
    await tester.pumpWidget(
      _app(
        catalog,
        AiModelPicker(
          value: 'alpha-model',
          compact: true,
          protocol: ModelProtocol.openai,
          endpoint: 'https://model.example/v1',
          onChanged: (_) {},
        ),
        scale: 1.5,
      ),
    );
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-model-search')), 'custom-model');
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-model-option-custom-model')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
