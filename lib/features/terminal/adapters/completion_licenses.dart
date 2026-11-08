import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

var _registered = false;

void registerCompletionLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/completions/LICENSE');
    yield LicenseEntryWithLineBreaks(const ['withfig/autocomplete — static completion data'], license);
  });
}
