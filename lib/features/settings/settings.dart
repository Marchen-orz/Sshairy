import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/theme.dart';
import '../../foundation/data_dir.dart';
import '../../foundation/json_file.dart';
import '../../foundation/result.dart';
import '../../foundation/shortcuts.dart';
import 'domain/background.dart';
import 'domain/translation_config.dart';

/// Chosen by the Windows runner before the engine starts (ADR-11), so a change applies after a restart.
enum Renderer { skia, impeller }

enum CursorShape { block, underline, bar }

enum RightClick { menu, paste }

enum HostView { grid, list }

enum HostOrder { name, recent }

enum FilesDock { left, right, bottom }

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
  Map<String, Object?> get schema => {
    'type': 'string',
    'enum': [for (final v in values) v.name],
  };
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

/// A font family name, or null for the default. Only the name is stored; a font that is not installed falls back.
class FontSetting extends SettingDef<String?> {
  const FontSetting(String key, {super.apply, super.agentExposed}) : super(key, null);

  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  @override
  bool accepts(Object? raw) =>
      raw == null || (raw is String && raw.trim().isNotEmpty && raw.length <= 64 && !_control.hasMatch(raw));
  @override
  String? decode(Object? raw) => raw as String?;
  @override
  Map<String, Object?> get schema => {
    'type': ['string', 'null'],
    'maxLength': 64,
  };
}

/// An owned image identifier; arbitrary source paths and URLs are never settings values.
class BackgroundImageSetting extends SettingDef<String?> {
  const BackgroundImageSetting(String key) : super(key, null, agentExposed: false);

  @override
  bool accepts(Object? raw) => raw == null || validBackgroundImageId(raw);
  @override
  String? decode(Object? raw) => raw as String?;
  @override
  Map<String, Object?> get schema => {
    'type': ['string', 'null'],
    'pattern': backgroundImageIdPattern,
  };
}

/// Owned image identifiers in display order: no duplicates, at most [maxItems], nothing but valid identifiers.
class BackgroundGallerySetting extends SettingDef<List<String>> {
  const BackgroundGallerySetting(String key, {this.maxItems = BackgroundImageLimits.galleryItems})
    : super(key, const [], agentExposed: false);

  final int maxItems;

  @override
  bool accepts(Object? raw) =>
      raw is List && raw.length <= maxItems && raw.every(validBackgroundImageId) && raw.toSet().length == raw.length;
  @override
  List<String> decode(Object? raw) => List.unmodifiable([for (final id in raw as List) id as String]);
  @override
  Map<String, Object?> get schema => {
    'type': 'array',
    'items': {'type': 'string', 'pattern': backgroundImageIdPattern},
    'maxItems': maxItems,
    'uniqueItems': true,
  };
}

/// A saved model or destination name; null means no explicit choice.
class OptionalStringSetting extends SettingDef<String?> {
  const OptionalStringSetting(String key, {this.maxLength = 256, super.agentExposed}) : super(key, null);

  final int maxLength;
  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  @override
  bool accepts(Object? raw) =>
      raw == null || (raw is String && raw.trim().isNotEmpty && raw.length <= maxLength && !_control.hasMatch(raw));
  @override
  String? decode(Object? raw) => raw as String?;
  @override
  Map<String, Object?> get schema => {
    'type': ['string', 'null'],
    'maxLength': maxLength,
  };
}

/// User-chosen keys, keyed by [AppShortcutAction]; missing actions keep their platform default.
class ShortcutSetting extends SettingDef<Map<String, String>> {
  const ShortcutSetting(String key) : super(key, const {}, agentExposed: false);

  @override
  bool accepts(Object? raw) {
    if (raw is! Map || raw.length > AppShortcutAction.values.length) return false;
    final seen = <String>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! String) return false;
      if (!AppShortcutAction.values.asNameMap().containsKey(entry.key)) return false;
      final binding = ShortcutBinding.parse(entry.value as String);
      if (binding == null || !seen.add(binding.encode())) return false;
    }
    return true;
  }

  @override
  Map<String, String> decode(Object? raw) => Map.unmodifiable({
    for (final entry in (raw as Map).entries)
      entry.key as String: ShortcutBinding.parse(entry.value as String)!.encode(),
  });
  @override
  Map<String, Object?> get schema => {
    'type': 'object',
    'maxProperties': AppShortcutAction.values.length,
    'additionalProperties': {'type': 'string'},
  };
}

class TranslationConfigSetting extends SettingDef<TranslationConfig> {
  const TranslationConfigSetting(String key) : super(key, const TranslationConfig(), agentExposed: false);

  @override
  bool accepts(Object? raw) {
    try {
      TranslationConfig.fromJson(raw);
      return true;
    } on FormatException {
      return false;
    }
  }

  @override
  TranslationConfig decode(Object? raw) => TranslationConfig.fromJson(raw);
  @override
  Object? encode(TranslationConfig value) => value.toJson();
  @override
  Map<String, Object?> get schema => {
    'type': 'object',
    'additionalProperties': false,
    'required': ['provider', 'endpoint', 'model', 'region', 'deepLFree'],
    'properties': {
      'provider': {
        'type': 'string',
        'enum': [for (final provider in TranslationProvider.values) provider.name],
      },
      'endpoint': {'type': 'string', 'maxLength': 2048},
      'model': {'type': 'string', 'maxLength': 128},
      'region': {'type': 'string', 'maxLength': 64},
      'deepLFree': {'type': 'boolean'},
    },
  };
}

abstract final class SettingKeys {
  static const themeMode = EnumSetting('themeMode', ThemeMode.system, ThemeMode.values);
  static const accent = EnumSetting('accent', Accent.blue, Accent.values);
  static const locale = OptionalChoice('locale', ['zh', 'en']);
  static const renderer = EnumSetting(
    'renderer',
    Renderer.impeller,
    Renderer.values,
    apply: ApplyMode.restart,
    agentExposed: false,
  );

  static const uiScale = DoubleSetting('uiScale', 1, .8, 1.5);
  static const uiFontFamily = FontSetting('uiFontFamily');
  static const uiFontSize = DoubleSetting('uiFontSize', AppFonts.uiSize, AppFonts.uiSizeMin, AppFonts.uiSizeMax);

  static const backgroundGallery = BackgroundGallerySetting('backgroundGallery');
  static const appBackgroundImage = BackgroundImageSetting('appBackgroundImage');
  static const appBackgroundOpacity = DoubleSetting('appBackgroundOpacity', BackgroundImageLimits.opacity, 0, 1);
  static const terminalBackgroundImage = BackgroundImageSetting('terminalBackgroundImage');
  static const terminalBackgroundOpacity = DoubleSetting(
    'terminalBackgroundOpacity',
    BackgroundImageLimits.opacity,
    0,
    1,
  );

  static const terminalFontFamily = FontSetting('terminalFontFamily');

  /// The terminal's font size; the key predates the interface size.
  static const fontSize = DoubleSetting('fontSize', 14, 8, 32);
  static const scrollback = IntSetting('scrollback', 2000, 500, 20000, apply: ApplyMode.newSessions);
  static const cursorShape = EnumSetting('cursorShape', CursorShape.block, CursorShape.values);
  static const copyOnSelect = BoolSetting('copyOnSelect', false);
  static const rightClick = EnumSetting('rightClick', RightClick.menu, RightClick.values);

  /// Guards against pasting commands that run at once; not the agent's to turn off.
  static const confirmPaste = BoolSetting('confirmPaste', true, agentExposed: false);
  static const completionTranslation = BoolSetting('completionTranslation', true, agentExposed: false);
  static const completionTranslationConcurrency = IntSetting(
    'completionTranslationConcurrency',
    0,
    0,
    32,
    agentExposed: false,
  );
  static const completionTranslationConfig = TranslationConfigSetting('completionTranslationConfig');

  static const connectTimeout = IntSetting('connectTimeout', 20, 5, 120, apply: ApplyMode.nextConnection);
  static const keepAlive = IntSetting('keepAlive', 30, 0, 300, apply: ApplyMode.nextConnection);
  static const idleTtl = IntSetting('idleTtl', 60, 0, 300);
  static const autoReconnect = BoolSetting('autoReconnect', false);

  static const hostView = EnumSetting('hostView', HostView.grid, HostView.values);
  static const hostOrder = EnumSetting('hostOrder', HostOrder.name, HostOrder.values);

  static const showMonitor = BoolSetting('showMonitor', true);

  /// The files panel beside every terminal tab; where it docks and how big it is are separate.
  static const showFiles = BoolSetting('showFiles', false);

  /// Seconds between monitor samples; the panel offers 1, 2, 3, 5 and 10.
  static const monitorInterval = IntSetting('monitorInterval', 3, 1, 10);

  /// Shown smaller while the window leaves no room for it; the stored value stays.
  static const monitorWidth = DoubleSetting(
    'monitorWidth',
    WorkspaceSize.monitor,
    WorkspaceSize.monitorMin,
    WorkspaceSize.monitorMax,
  );
  static const filesDock = EnumSetting('filesDock', FilesDock.bottom, FilesDock.values);
  static const navigationExpanded = BoolSetting('navigationExpanded', false);
  static const navigationWidth = DoubleSetting(
    'navigationWidth',
    WorkspaceSize.navigationExpanded,
    WorkspaceSize.navigationMin,
    WorkspaceSize.navigationMax,
  );

  /// Asks before every quit; running transfers, unsaved edits and tunnels ask regardless.
  static const confirmQuit = BoolSetting('confirmQuit', true, agentExposed: false);

  static const showHidden = BoolSetting('showHidden', true);

  /// The import dialog has opened by itself once, for an empty host library (docs/HOST_IMPORT.md).
  static const importOffered = BoolSetting('importOffered', false, agentExposed: false);
  static const transferConcurrency = IntSetting('transferConcurrency', 3, 1, 8);

  /// The last Agent model chosen in the panel; kept only for the same protocol and endpoint.
  static const agentModel = OptionalStringSetting('agentModel', maxLength: 256, agentExposed: false);
  static const agentModelEndpoint = OptionalStringSetting('agentModelEndpoint', maxLength: 4096, agentExposed: false);

  /// User overrides; actions not present use their platform default.
  static const shortcuts = ShortcutSetting('shortcuts');

  static const List<SettingDef<Object?>> all = [
    themeMode,
    accent,
    locale,
    renderer,
    uiScale,
    uiFontFamily,
    uiFontSize,
    backgroundGallery,
    appBackgroundImage,
    appBackgroundOpacity,
    terminalBackgroundImage,
    terminalBackgroundOpacity,
    terminalFontFamily,
    fontSize,
    scrollback,
    cursorShape,
    copyOnSelect,
    rightClick,
    confirmPaste,
    completionTranslation,
    completionTranslationConcurrency,
    completionTranslationConfig,
    connectTimeout,
    keepAlive,
    idleTtl,
    autoReconnect,
    hostView,
    hostOrder,
    showMonitor,
    showFiles,
    monitorInterval,
    monitorWidth,
    filesDock,
    navigationExpanded,
    navigationWidth,
    confirmQuit,
    showHidden,
    importOffered,
    transferConcurrency,
    agentModel,
    agentModelEndpoint,
    shortcuts,
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
  String? get uiFontFamily => get(SettingKeys.uiFontFamily);
  double get uiFontSize => get(SettingKeys.uiFontSize);
  double get uiScale => get(SettingKeys.uiScale);
  String? get terminalFontFamily => get(SettingKeys.terminalFontFamily);
  Map<String, String> get shortcuts => get(SettingKeys.shortcuts);

  Settings copyWith(Map<String, Object?> decoded) => Settings({..._values, ...decoded});

  /// Bad or unknown values fall back to defaults rather than failing the start.
  factory Settings.fromJson(Map<String, dynamic> j) => Settings({
    for (final d in SettingKeys.all)
      if (j.containsKey(d.key) && d.accepts(j[d.key])) d.key: d.decode(j[d.key]),
  });

  Map<String, dynamic> toJson() => {'schemaVersion': 1, for (final d in SettingKeys.all) d.key: d.encode(get(d))};
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<Settings> {
  late final JsonFile _file = JsonFile(
    '${ref.read(dataDirProvider)}/settings.json',
    backups: true,
    validate: (json) {
      for (final definition in SettingKeys.all) {
        if (json.containsKey(definition.key) && !definition.accepts(json[definition.key])) {
          throw FormatException('invalid setting ${definition.key}');
        }
      }
    },
  );

  @override
  Settings build() => Settings.fromJson(_file.read() ?? const {});

  Future<void> _pending = Future.value();
  Future<void> get saved => _pending.then((_) => _file.idle);
  int get revision => _file.revision;

  Future<void> _change(Map<String, Object?> decoded, {int? expectedRevision}) {
    final next = _pending.then((_) async {
      final settings = state.copyWith(decoded);
      await _file.write(settings.toJson(), expectedRevision: expectedRevision);
      state = settings;
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> set<T>(SettingDef<T> d, T value) {
    if (!d.accepts(d.encode(value))) throw ArgumentError.value(value, d.key);
    return _change({d.key: value});
  }

  /// Applies JSON values all or nothing. With [exposedOnly], settings kept from the agent are refused too.
  Future<Result<void>> patch(Map<String, Object?> raw, {bool exposedOnly = false, int? expectedRevision}) async {
    final decoded = <String, Object?>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final d = SettingKeys.byKey(key);
      if (d == null || (exposedOnly && !d.agentExposed)) return Err(AppError('unknownSetting', detail: key));
      if (!d.accepts(value)) return Err(AppError('invalidArgument', detail: key));
      decoded[key] = d.decode(value);
    }
    await _change(decoded, expectedRevision: expectedRevision);
    return const Ok(null);
  }
}
