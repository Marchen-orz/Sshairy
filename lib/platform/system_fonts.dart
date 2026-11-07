import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemFont {
  const SystemFont(this.name, {this.mono = false});

  final String name;
  final bool mono;
}

/// Installed font families, from the Windows runner; empty elsewhere, where the pickers offer the defaults only.
Future<List<SystemFont>> loadSystemFonts([MethodChannel channel = const MethodChannel('sshairy/window')]) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return const [];
  try {
    final raw = await channel.invokeListMethod<Object?>('fonts') ?? const [];
    return [
      for (final entry in raw)
        if (entry case [final String name, final bool mono]) SystemFont(name, mono: mono),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  } on MissingPluginException {
    return const [];
  }
}
