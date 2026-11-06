import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import 'dispatcher.dart';

enum PaletteSection { hosts, sessions, actions }

class PaletteEntry {
  const PaletteEntry({
    required this.section,
    required this.title,
    required this.icon,
    required this.run,
    this.subtitle = '',
    this.keywords = '',
  });

  final PaletteSection section;
  final String title, subtitle, keywords;
  final IconData icon;
  final Future<void> Function() run;

  bool matches(String query) => '$title $subtitle $keywords'.toLowerCase().contains(query);
}

/// Calls a capability with origin `palette`; business actions go through the dispatcher, not around it.
typedef PaletteDispatch = Future<void> Function(String id, [Map<String, Object?> args]);

class PaletteContext {
  const PaletteContext(this.context, this.ref, this.l, this.dispatch);

  /// Where the palette was opened from; still mounted after the palette closes.
  final BuildContext context;
  final WidgetRef ref;
  final AppLocalizations l;
  final PaletteDispatch dispatch;
}

/// Each feature contributes entries for what it currently offers; UI-only actions (open settings) can run directly.
typedef PaletteSource = List<PaletteEntry> Function(PaletteContext c);

/// Provided by the app's composition root (lib/app), which knows every feature.
final capabilityDispatcherProvider = Provider<CapabilityDispatcher>((_) => throw UnimplementedError());
final paletteSourcesProvider = Provider<List<PaletteSource>>((_) => const []);
