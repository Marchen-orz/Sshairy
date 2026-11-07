import '../l10n/app_localizations.dart';
import 'brand_palette.dart';

extension AccentName on Accent {
  String label(AppLocalizations l) => switch (this) {
    Accent.blue => l.themeNameBlue,
    Accent.green => l.themeNameGreen,
    Accent.violet => l.themeNameViolet,
    Accent.orange => l.themeNameOrange,
    Accent.deepSea => l.themeNameDeepSea,
    Accent.pink => l.themeNamePink,
  };
}
