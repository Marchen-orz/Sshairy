import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/theme.dart';
import '../../foundation/data_dir.dart';
import '../../foundation/json_file.dart';
import '../../foundation/result.dart';

/// Chosen by the Windows runner before the engine starts (ADR-11), so a change applies after a restart.
enum Renderer { skia, impeller }

enum CursorShape { block, underline, bar }

enum RightClick { menu, paste }

/// What the runner started with; null where the runner does not choose.
final runningRendererProvider = Provider<Renderer?>((_) => null);

/// When a changed value takes effect, so the panel can say so.
enum ApplyMode { immediate, newSessions, nextConnection, restart }

/// One entry of settings.json: its default, the values it accepts and when a change applies (docs/MODULES.md §7).
/// Capabilities validate against these, so a setting added here is reachable from the palette and, if exposed,
/// the agent without further code.
sealed class SettingDef<T> {
  const SettingDef(this.key, this.defaultValue, {this.apply = ApplyMode.immediate, this.agentExposed = true});

  final String key;
  final T defaultValue;
  final ApplyMode apply;

  /// False for choices that are the user's alone: security trade-offs and platform switches.
  final bool agentExposed;

  bool accepts(Object? raw);

  /// Only called on values [accepts] allowed.
  T decode(Object? raw);
  Object? encode(T value) => value;
  Map<String, Object?> get schema;
}

class EnumSetting<T extends Enum> extends SettingDef<T> {
  const EnumSetting(super.key, super.defaultValue, this.values, {super.apply, super.agentExposed});

  final List<T> values;

  @override
  bool accepts(Object? raw) => raw is String && values.any((v) => v.name == raw);
  @override
  T decode(Object? raw) => values.firstWhere((v) => v.name == raw);
  @override
  Object? encode(T value) => value.name;
  @override
  Map<String, Object?> get schema => {'type': 'string', 'enum': [for (final v in values) v.name]};
}

class IntSetting extends SettingDef<int> {
  const IntSetting(super.key, super.defaultValue, this.min, this.max, {super.apply, super.agentExposed});

  final int min, max;

  @override
  bool accepts(Object? raw) => raw is num && raw == raw.roundToDouble() && raw >= min && raw <= max;
  @override
  int decode(Object? raw) => (raw as num).toInt();
  @override
  Map<String, Object?> get schema => {'type': 'integer', 'minimum': min, 'maximum': max};
}

class DoubleSetting extends SettingDef<double> {
  const DoubleSetting(super.key, super.defaultValue, this.min, this.max, {super.apply, super.agentExposed});

  final double min, max;

  @override
  bool accepts(Object? raw) => raw is num && raw >= min && raw <= max;
  @override
  double decode(Object? raw) => (raw as num).toDouble();
  @override
  Map<String, Object?> get schema => {'type': 'number', 'minimum': min, 'maximum': max};
}

class BoolSetting extends SettingDef<bool> {
  const BoolSetting(super.key, super.defaultValue, {super.apply, super.agentExposed});

  @override
  bool accepts(Object? raw) => raw is bool;
  @override
  bool decode(Object? raw) => raw as bool;
  @override
  Map<String, Object?> get schema => {'type': 'boolean'};
}

/// One of [options], or null for "follow the system".
class OptionalChoice extends SettingDef<String?> {
  const OptionalChoice(String key, this.options, {super.apply, super.agentExposed}) : super(key, null);

  final List<String> options;

  @override
  bool accepts(Object? raw) => raw == null || options.contains(raw);
  @override
  String? decode(Object? raw) => raw as String?;
  @override
  Map<String, Object?> get schema => {
        'type': ['string', 'null'],
        'enum': [...options, null],
      };
}

abstract final class SettingKeys {
  static const themeMode = EnumSetting('themeMode', ThemeMode.system, ThemeMode.values);
  static const accent = EnumSetting('accent', Accent.blue, Accent.values);
  static const locale = OptionalChoice('locale', ['zh', 'en']);
  static const renderer = EnumSetting('renderer', Renderer.skia, Renderer.values,
      apply: ApplyMode.restart, agentExposed: false);

  static const fontSize = DoubleSetting('fontSize', 14, 8, 32);
  static const scrollback = IntSetting('scrollback', 2000, 500, 20000, apply: ApplyMode.newSessions);
  static const cursorShape = EnumSetting('cursorShape', CursorShape.block, CursorShape.values);
  static const copyOnSelect = BoolSetting('copyOnSelect', false);
  static const rightClick = EnumSetting('rightClick', RightClick.menu, RightClick.values);

  /// Guards against pasting commands that run at once; not the agent's to turn off.
  static const confirmPaste = BoolSetting('confirmPaste', true, agentExposed: false);

  static const connectTimeout = IntSetting('connectTimeout', 20, 5, 120, apply: ApplyMode.nextConnection);
  static const keepAlive = IntSetting('keepAlive', 30, 0, 300, apply: ApplyMode.nextConnection);
  static const idleTtl = IntSetting('idleTtl', 60, 0, 300);
  static const autoReconnect = BoolSetting('autoReconnect', false);

  static const showHidden = BoolSetting('showHidden', false);
  static const transferConcurrency = IntSetting('transferConcurrency', 3, 1, 8);

  static const List<SettingDef<Object?>> all = [
    themeMode, accent, locale, renderer, fontSize, scrollback, cursorShape, copyOnSelect, rightClick, confirmPaste,
    connectTimeout, keepAlive, idleTtl, autoReconnect, showHidden, transferConcurrency,
  ];

  static SettingDef<Object?>? byKey(String key) => all.where((d) => d.key == key).firstOrNull;
}

class Settings {
  const Settings([this._values = const {}]);

  /// Only accepted, decoded values; anything missing is the default.
  final Map<String, Object?> _values;

  T get<T>(SettingDef<T> d) => _values.containsKey(d.key) ? _values[d.key] as T : d.defaultValue;

  ThemeMode get themeMode => get(SettingKeys.themeMode);
  Accent get accent => get(SettingKeys.accent);
  String? get locale => get(SettingKeys.locale);
  Renderer get renderer => get(SettingKeys.renderer);
  double get fontSize => get(SettingKeys.fontSize);

  Settings copyWith(Map<String, Object?> decoded) => Settings({..._values, ...decoded});

  /// Bad or unknown values fall back to defaults rather than failing the start.
  factory Settings.fromJson(Map<String, dynamic> j) => Settings({
        for (final d in SettingKeys.all)
          if (j.containsKey(d.key) && d.accepts(j[d.key])) d.key: d.decode(j[d.key]),
      });

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        for (final d in SettingKeys.all) d.key: d.encode(get(d)),
      };
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<Settings> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/settings.json');

  @override
  Settings build() => Settings.fromJson(_file.read() ?? const {});

  Future<void> set<T>(SettingDef<T> d, T value) async {
    state = state.copyWith({d.key: value});
    await _file.write(state.toJson());
  }

  /// Applies JSON values all or nothing. With [exposedOnly], settings kept from the agent are refused too.
  Future<Result<void>> patch(Map<String, Object?> raw, {bool exposedOnly = false}) async {
    final decoded = <String, Object?>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final d = SettingKeys.byKey(key);
      if (d == null || (exposedOnly && !d.agentExposed)) return Err(AppError('unknownSetting', detail: key));
      if (!d.accepts(value)) return Err(AppError('invalidArgument', detail: key));
      decoded[key] = d.decode(value);
    }
    state = state.copyWith(decoded);
    await _file.write(state.toJson());
    return const Ok(null);
  }
}
