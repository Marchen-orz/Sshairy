import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/data_dir.dart';
import '../../foundation/json_file.dart';

/// Chosen by the Windows runner before the engine starts (ADR-11), so a change applies after a restart.
enum Renderer { skia, impeller }

/// What the runner started with; null where the runner does not choose.
final runningRendererProvider = Provider<Renderer?>((_) => null);

class Settings {
  const Settings({this.themeMode = ThemeMode.system, this.fontSize = 14, this.locale, this.renderer = Renderer.skia});

  final ThemeMode themeMode;
  final double fontSize;

  /// null follows the system language.
  final String? locale;

  final Renderer renderer;

  static const minFontSize = 8.0, maxFontSize = 32.0;

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
        fontSize: ((j['fontSize'] as num?)?.toDouble() ?? 14).clamp(minFontSize, maxFontSize),
        locale: const ['zh', 'en'].contains(j['locale']) ? j['locale'] as String : null,
        renderer: Renderer.values.asNameMap()[j['renderer']] ?? Renderer.skia,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'themeMode': themeMode.name,
        'fontSize': fontSize,
        'locale': locale,
        'renderer': renderer.name,
      };
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<Settings> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/settings.json');

  @override
  Settings build() => Settings.fromJson(_file.read() ?? const {});

  Future<void> update({ThemeMode? themeMode, double? fontSize, String? Function()? locale, Renderer? renderer}) {
    state = Settings(
      themeMode: themeMode ?? state.themeMode,
      fontSize: (fontSize ?? state.fontSize).clamp(Settings.minFontSize, Settings.maxFontSize),
      locale: locale != null ? locale() : state.locale,
      renderer: renderer ?? state.renderer,
    );
    return _file.write(state.toJson());
  }
}
