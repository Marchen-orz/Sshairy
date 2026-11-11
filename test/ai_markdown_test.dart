import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/ai/adapters/markdown_view.dart';
import 'package:sshairy/l10n/app_localizations.dart';

Widget _app(
  String data, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
  Accent accent = Accent.blue,
  Future<bool> Function(String)? openLink,
  Map<String, String> executionReferences = const {},
  ValueChanged<String>? onExecution,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: buildTheme(brightness, accent),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(Space.md),
      child: SelectionArea(
        child: AiMarkdown(
          data: data,
          openLink: openLink ?? _rejectLink,
          executionReferences: executionReferences,
          onExecution: onExecution,
        ),
      ),
    ),
  ),
);

Future<bool> _rejectLink(String value) async => false;

TextSpan? _span(InlineSpan span, String text) {
  if (span is! TextSpan) return null;
  if (span.text == text) return span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final found = _span(child, text);
    if (found != null) return found;
  }
  return null;
}

TapGestureRecognizer? _link(InlineSpan span, String label) {
  if (span is! TextSpan) return null;
  if (span.toPlainText() == label && span.recognizer is TapGestureRecognizer) {
    return span.recognizer! as TapGestureRecognizer;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    final found = _link(child, label);
    if (found != null) return found;
  }
  return null;
}

void main() {
  testWidgets(
    'assistant Markdown renders headings, lists, quotes, inline code and tables',
    (tester) async {
      await tester.pumpWidget(
        _app('''
## Server status

The **service** is ready; run `uptime`.

- First check
- Second check

> Read only

| Field | Value |
| --- | --- |
| Status | Healthy |
'''),
      );
      await tester.pump();
      expect(find.text('Server status', findRichText: true), findsOneWidget);
      expect(find.text('First check', findRichText: true), findsOneWidget);
      expect(find.text('Second check', findRichText: true), findsOneWidget);
      expect(find.text('Read only', findRichText: true), findsOneWidget);
      expect(find.text('Healthy', findRichText: true), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(find.textContaining('## Server status'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'images never create image widgets and links open only clicked safe web targets',
    (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        _app(
          '''
![Remote image](https://images.example/pixel.png)

![Local image](file:///C:/private.png)

![Embedded image](data:image/png;base64,aGVsbG8=)

[Web](https://docs.example/guide)

[Script](javascript:alert(1))

[File](file:///C:/private.txt)

[Embedded](data:text/html,hello)

[Userinfo](https://user:password@docs.example/)
''',
          openLink: (value) async {
            opened.add(value);
            return true;
          },
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.text('Remote image'), findsOneWidget);
      expect(find.text('Local image'), findsOneWidget);
      expect(find.text('Embedded image'), findsOneWidget);
      expect(opened, isEmpty);

      for (final label in ['Script', 'File', 'Embedded', 'Userinfo', 'Web']) {
        final recognizer = tester
            .widgetList<RichText>(find.byType(RichText))
            .map((widget) => _link(widget.text, label))
            .whereType<TapGestureRecognizer>()
            .first;
        recognizer.onTap!();
        await tester.pump();
      }
      expect(opened, ['https://docs.example/guide']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long fenced code and wide tables scroll within a narrow scaled panel',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(300, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final long = List.filled(12, 'server-output').join('-');
      await tester.pumpWidget(
        _app('''
### Summary

A short explanation with **emphasis**.

```sh
printf '$long'
```

| First column | Second column | Third column |
| --- | --- | --- |
| $long | $long | $long |
''', textScale: 1.5),
      );
      await tester.pump();
      final horizontal = tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .where((widget) => widget.scrollDirection == Axis.horizontal);
      expect(horizontal.length, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only exact known execution IDs in inline code become local record references',
    (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        _app(
          'Checked `exec-1`, unknown `missing`, and\n\n```\nexec-1\n```\n',
          executionReferences: const {'exec-1': 'exec-1'},
          onExecution: opened.add,
        ),
      );
      await tester.pump();
      expect(find.text('Execution record'), findsOneWidget);
      final unknown = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere(
            (widget) => widget.text.toPlainText().contains('missing'),
          );
      expect(_span(unknown.text, 'missing'), isNotNull);
      await tester.tap(find.text('Execution record'));
      await tester.pump();
      expect(opened, ['exec-1']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'inline code uses an emphasized ${brightness.name} background with readable text',
      (tester) async {
        await tester.pumpWidget(
          _app('Run `uptime` now', brightness: brightness),
        );
        await tester.pump();
        final context = tester.element(find.byType(AiMarkdown));
        final scheme = Theme.of(context).colorScheme;
        final rich = tester
            .widgetList<RichText>(find.byType(RichText))
            .firstWhere(
              (widget) => widget.text.toPlainText() == 'Run uptime now',
            );
        final code = _span(rich.text, 'uptime');
        expect(code, isNotNull);
        expect(
          code!.style!.backgroundColor,
          Color.alphaBlend(
            scheme.primary.withValues(alpha: .18),
            scheme.surface,
          ),
        );
        expect(code.style!.color, scheme.onSurface);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
