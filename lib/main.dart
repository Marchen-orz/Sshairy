import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/composition.dart';
import 'app/configuration.dart';
import 'features/capabilities/api.dart';
import 'platform/desktop_window.dart';
import 'app/shutdown.dart';
import 'design/theme.dart';
import 'features/settings/api.dart';
import 'features/workspace/api.dart';
import 'foundation/data_dir.dart';
import 'foundation/diagnostics.dart';
import 'l10n/app_localizations.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await DesktopWindow.instance.initialize();
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final diagnostics = DiagnosticLog('${dir.path}/logs');
  diagnostics.record(DiagnosticArea.application, DiagnosticAction.start, DiagnosticOutcome.started);
  FlutterError.onError = (_) =>
      diagnostics.record(DiagnosticArea.application, DiagnosticAction.uncaught, DiagnosticOutcome.failed);
  PlatformDispatcher.instance.onError = (_, _) {
    diagnostics.record(DiagnosticArea.application, DiagnosticAction.uncaught, DiagnosticOutcome.failed);
    return true;
  };
  final renderer =
      Renderer.values.asNameMap()[args
          .firstWhere((a) => a.startsWith('--renderer='), orElse: () => '')
          .replaceFirst('--renderer=', '')];
  runApp(
    ProviderScope(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        diagnosticLogProvider.overrideWithValue(diagnostics),
        runningRendererProvider.overrideWithValue(renderer),
        ...appOverrides(),
      ],
      child: const SshairyApp(),
    ),
  );
}

class SshairyApp extends ConsumerWidget {
  const SshairyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problem = ref.watch(configurationCheckProvider);
    final settings = problem == null ? ref.watch(settingsProvider) : const Settings();
    return MaterialApp(
      title: 'sshairy',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, settings.accent),
      darkTheme: buildTheme(Brightness.dark, settings.accent),
      themeMode: settings.themeMode,
      locale: settings.locale == null ? null : Locale(settings.locale!),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: problem == null
          ? ShutdownGuard(child: WorkspacePage(openPalette: showCommandPalette))
          : ConfigurationErrorPage(problem),
    );
  }
}
