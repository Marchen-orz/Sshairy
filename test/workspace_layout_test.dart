import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/tool_panel.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/workspace/presentation/workspace_page.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

const _hosts = [
  Host(id: HostId('web'), label: 'web-1', address: 'web.example', username: 'u', group: 'Prod/Web'),
  Host(id: HostId('db'), label: 'db-1', address: 'db.example', username: 'u', group: 'Prod'),
  Host(id: HostId('local'), label: 'local', address: 'localhost', username: 'u'),
];

class _Hosts extends HostsNotifier {
  @override
  List<Host> build() => _hosts;
}

class _TestAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

void main() {
  testWidgets('library navigation collapses at the minimum window size without hiding actions', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-layout-');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dataDirProvider.overrideWithValue(dir.path)],
        child: DefaultAssetBundle(
          bundle: _TestAssets(),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Keys'), findsOneWidget);
    expect(find.byTooltip('Keys'), findsOneWidget, reason: 'one key-library entry');
    expect(find.byTooltip('Trusted host keys'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(960, 640));
    await tester.pumpAndSettle();
    expect(find.text('Keys'), findsNothing);
    expect(find.byTooltip('Keys'), findsOneWidget);
    expect(find.byTooltip('Trusted host keys'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host tree searches collapsed descendants and connects through its callback', (tester) async {
    Host? selected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [hostsProvider.overrideWith(_Hosts.new)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(width: 224, child: HostTree(onConnect: (h) => selected = h)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Prod'), findsOneWidget);
    expect(find.text('Web'), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget);
    await tester.tap(find.text('Prod'));
    await tester.pump();
    expect(find.text('web-1'), findsNothing);
    await tester.enterText(find.byType(TextField), 'web.example');
    await tester.pump();
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('db-1'), findsNothing);
    expect(find.text('local'), findsNothing);
    await tester.tap(find.text('web-1'));
    expect(selected?.id, const HostId('web'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool panel preserves editor state when moving over a narrow main view; Escape closes it', (
    tester,
  ) async {
    var open = true;
    var width = 1000.0;
    late StateSetter rebuild;
    const mainKey = ValueKey('main');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SizedBox(
                  width: width,
                  height: 500,
                  child: ToolPanel(
                    open: open,
                    onClose: () => setState(() => open = false),
                    closeLabel: 'Close panel',
                    resizeLabel: 'Resize panel',
                    panel: const TextField(),
                    child: const SizedBox(key: mainKey),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    // The test's physical viewport must be larger than the requested logical width.
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(mainKey)).width, 639);
    await tester.enterText(find.byType(TextField), 'unsent draft');
    rebuild(() => width = 780);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(mainKey)).width, 780);
    expect(find.text('unsent draft'), findsOneWidget);
    expect(find.descendant(of: find.byType(ToolPanel), matching: find.byType(ModalBarrier)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(open, isFalse);
    expect(find.byType(TextField), findsNothing);
    expect(tester.getSize(find.byKey(mainKey)).width, 780);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool panel commits a bounded width on release and supports keyboard resizing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const mainKey = ValueKey('main');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: ToolPanel(
            open: true,
            onClose: () {},
            closeLabel: 'Close panel',
            resizeLabel: 'Resize panel',
            panel: const Text('files'),
            child: const SizedBox(key: mainKey),
          ),
        ),
      ),
    );
    final handle = find.bySemanticsLabel('Resize panel');
    expect(tester.getSize(find.byKey(mainKey)).width, 1239);
    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveBy(const Offset(-20, 0));
    await drag.moveBy(const Offset(-400, 0));
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1239, reason: 'dragging only paints a guide');
    await drag.up();
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1039, reason: '560 px maximum');
    await tester.tap(handle);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1063);
    await tester.drag(handle, const Offset(500, 0));
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1299, reason: '300 px minimum');
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}
