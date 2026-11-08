import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/settings/adapters/background_images.dart';
import 'package:sshairy/features/settings/application/background_images.dart';
import 'package:sshairy/features/settings/domain/background.dart';
import 'package:sshairy/features/settings/presentation/background_image.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/l10n/app_localizations.dart';
import 'package:xterm2/xterm.dart' show TerminalView;

import 'connection_manager_test.dart' show FakeTransport;

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xff3688aa), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('the terminal image layer follows its own slot, opacity and visibility', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-terminal-background-');
    final source = File('${dir.path}/source.png');
    await tester.runAsync(() async => source.writeAsBytes(await _png()));
    final store = BackgroundImageStore('${dir.path}/owned', pick: () async => source.path);
    final container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), backgroundImageStoreProvider.overrideWithValue(store)],
    );
    final manager = ConnectionManager((_, _, _) async => FakeTransport(), park: Duration.zero);
    final session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
      manager,
      autoConnect: false,
    );
    Future<void> show({bool visible = true, ScrollBehavior behavior = const AppScrollBehavior()}) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            scrollBehavior: behavior,
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SizedBox.expand(child: TerminalPane(session, active: true, visible: visible)),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    double renderer() => tester.widget<TerminalView>(find.byType(TerminalView)).backgroundOpacity;

    late BackgroundImages images;
    await tester.runAsync(() async {
      container.read(settingsProvider);
      images = container.read(backgroundImagesProvider.notifier);
    });

    try {
      await show();
      expect(find.byType(BackgroundImageView), findsNothing);
      expect(renderer(), 1);

      await tester.runAsync(() async {
        expect(await images.choose(BackgroundSlot.terminal), isA<Ok<void>>());
        await images.saveOpacity(BackgroundSlot.terminal, .3);
        final id = container.read(settingsProvider).get(SettingKeys.terminalBackgroundImage);
        final stream = FileImage(store.file(id)!).resolve(ImageConfiguration.empty);
        final ready = Completer<void>();
        final listener = ImageStreamListener(
          (_, _) {
            if (!ready.isCompleted) ready.complete();
          },
          onError: (Object error, StackTrace? stack) {
            if (!ready.isCompleted) ready.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        try {
          await ready.future.timeout(const Duration(seconds: 5));
        } finally {
          stream.removeListener(listener);
        }
      });
      await tester.pump();
      expect(find.byType(BackgroundImageView), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      // The renderer's fill carries what the image does not, so the image shows at exactly 30%.
      expect(renderer(), closeTo(.7, 1e-9));
      expect(container.read(settingsProvider).get(SettingKeys.appBackgroundImage), isNull);

      final terminal = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
      final grid = (terminal.viewWidth, terminal.viewHeight);
      await show(behavior: const MaterialScrollBehavior());
      expect(
        (terminal.viewWidth, terminal.viewHeight),
        grid,
        reason: 'global gutters must not shrink terminal columns',
      );
      await show();
      expect((terminal.viewWidth, terminal.viewHeight), grid);
      terminal.write('\x1b]11;#223344\x07');
      await tester.pump();
      expect(find.byType(BackgroundImageView), findsNothing);
      expect(renderer(), 1);
      terminal.write('\x1b]111\x07');
      await tester.pump();
      expect(find.byType(BackgroundImageView), findsOneWidget);
      expect(renderer(), closeTo(.7, 1e-9));
      terminal.write('\x1b[?5h');
      await tester.pump();
      expect(find.byType(BackgroundImageView), findsNothing);
      expect(renderer(), 1);
      terminal.write('\x1b[?5l');
      await tester.pump();
      expect(find.byType(BackgroundImageView), findsOneWidget);

      await show(visible: false);
      expect(find.byType(BackgroundImageView), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(renderer(), 1);

      await show();
      expect(find.byType(BackgroundImageView), findsOneWidget);

      images.previewOpacity(BackgroundSlot.terminal, 0);
      await tester.pump();
      expect(find.byType(BackgroundImageView), findsNothing);
      expect(renderer(), 1);
      images.cancelPreview(BackgroundSlot.terminal);
      await tester.pump();
      expect(renderer(), closeTo(.7, 1e-9));

      await tester.runAsync(() => images.reset(BackgroundSlot.terminal));
      await tester.pump();
      expect(find.byType(BackgroundImageView), findsNothing);
      expect(renderer(), 1);
      expect(container.read(settingsProvider).get(SettingKeys.terminalBackgroundImage), isNull);
      expect(
        container.read(settingsProvider).get(SettingKeys.terminalBackgroundOpacity),
        BackgroundImageLimits.opacity,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      session.close();
      manager.closeAll();
      container.dispose();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        dir.deleteSync(recursive: true);
      });
    }
  });
}
