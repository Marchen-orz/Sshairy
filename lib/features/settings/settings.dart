import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/data_dir.dart';
import '../../foundation/json_file.dart';

class Settings {
  const Settings({this.themeMode = ThemeMode.system, this.fontSize = 14, this.locale});

  final ThemeMode themeMode;
  final double fontSize;

  /// null follows the system language.
  final String? locale;

  static const minFontSize = 8.0, maxFontSize = 32.0;

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
        fontSize: ((j['fontSize'] as num?)?.toDouble() ?? 14).clamp(minFontSize, maxFontSize),
        locale: const ['zh', 'en'].contains(j['locale']) ? j['locale'] as String : null,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'themeMode': themeMode.name,
        'fontSize': fontSize,
        'locale': locale,
      };
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<Settings> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/settings.json');

  @override
  Settings build() => Settings.fromJson(_file.read() ?? const {});

  Future<void> update({ThemeMode? themeMode, double? fontSize, String? Function()? locale}) {
    state = Settings(
      themeMode: themeMode ?? state.themeMode,
      fontSize: (fontSize ?? state.fontSize).clamp(Settings.minFontSize, Settings.maxFontSize),
      locale: locale != null ? locale() : state.locale,
    );
    return _file.write(state.toJson());
  }
}
