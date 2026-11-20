import 'dart:io' show Platform, exit;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/composition.dart';
import 'app/configuration.dart';
import 'app/image_cache_budget.dart';
import 'app/link_bridge.dart';
import 'app/mcp/settings.dart';
import 'features/capabilities/api.dart';
import 'features/ai/api.dart' show AgentHostApprovalPrompts;
import 'platform/desktop_window.dart';
import 'platform/device_form_factor.dart';
import 'platform/single_instance.dart';
import 'app/shutdown.dart';
import 'app/window_brand_icon.dart';
import 'design/theme.dart';
import 'design/scrolling.dart';
import 'design/interface_scale.dart';
import 'features/settings/api.dart';
import 'features/workspace/api.dart';
import 'features/terminal/api.dart' show registerCompletionLicenses;
import 'foundation/data_dir.dart';
import 'foundation/diagnostics.dart';
import 'l10n/app_localizations.dart';

/// Held for the process lifetime, so the lock and the loopback listener stay alive with it.
SingleInstance? _instance;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  registerCompletionLicenses();
  await DesktopWindow.instance.initialize();
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  // A second launch only brings the running desktop window forward; mobile OS manages task instances natively.
  if (isDesktopPlatform && Platform.environment['FLUTTER_TEST'] != 'true') {
    final window = DesktopWindow.instance;
    _instance = await SingleInstance.acquire(
      dir.path,
      show: window.show,
      allowForeground: Platform.isWindows ? window.allowForeground : null,
    );
    if (!_instance!.isPrimary) exit(0);
  }
  final diagnostics = DiagnosticLog('${dir.path}/logs');
  diagnostics.record(DiagnosticArea.application, DiagnosticAction.start, DiagnosticOutcome.started);
  // The log keeps no error text (docs/DIAGNOSTICS.md); a debug run still shows it on the console.
  FlutterError.onError = (details) {
    diagnostics.record(DiagnosticArea.application, DiagnosticAction.uncaught, DiagnosticOutcome.failed);
    if (kDebugMode) FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    diagnostics.record(DiagnosticArea.application, DiagnosticAction.uncaught, DiagnosticOutcome.failed);
    if (kDebugMode) debugPrint('uncaught: $error\n$stack');
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

class SshairyApp extends ConsumerStatefulWidget {
  const SshairyApp({super.key, this.window});

  final DesktopWindow? window;

  @override
  ConsumerState<SshairyApp> createState() => _SshairyAppState();
}

class _SshairyAppState extends ConsumerState<SshairyApp> {
  (Accent, double, String?, String?)? _themeInputs;
  late ThemeData _theme, _darkTheme;

  @override
  Widget build(BuildContext context) {
    final problem = ref.watch(configurationCheckProvider);
    final settings = problem == null ? ref.watch(settingsProvider) : const Settings();
    final inputs = (settings.accent, settings.uiFontSize, settings.uiFontFamily, settings.terminalFontFamily);
    if (_themeInputs != inputs) {
      _themeInputs = inputs;
      _theme = buildTheme(Brightness.light, inputs.$1, inputs.$2, inputs.$3, inputs.$4);
      _darkTheme = buildTheme(Brightness.dark, inputs.$1, inputs.$2, inputs.$3, inputs.$4);
    }
    return MaterialApp(
      title: 'Sshairy',
      scrollBehavior: const AppScrollBehavior(),
      debugShowCheckedModeBanner: false,
      theme: _theme,
      darkTheme: _darkTheme,
      // Interpolating ThemeData rebuilds every themed form field on every tick.
      // Apply the palette once; controls keep their own local transitions.
      themeAnimationDuration: Duration.zero,
      themeMode: settings.themeMode,
      builder: (context, child) => MotionScope(
        level: settings.motion,
        child: ImageCacheBudget(
          child: WindowBrandIcon(
            window: widget.window,
            child: InterfaceScale(scale: settings.uiScale, child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
      locale: settings.locale == null ? null : Locale(settings.locale!),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: problem == null
          ? ShutdownGuard(
              window: widget.window,
              child: StartupUpdatePrompt(
                // Widget tests and probes keep their network and dialogs out of the start-up frames.
                enabled: Platform.environment['FLUTTER_TEST'] != 'true',
                child: LinkHostLifecycle(
                  child: McpHostPrompts(
                    child: AgentHostApprovalPrompts(child: WorkspacePage(openPalette: showCommandPalette)),
                  ),
                ),
              ),
            )
          : ConfigurationErrorPage(problem),
    );
  }
}
