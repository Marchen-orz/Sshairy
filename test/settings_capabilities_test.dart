import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/capabilities/settings.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/foundation/result.dart';

void main() {
  test('settings capability separates revision metadata from the settings patch', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-settings-capabilities-');
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });
    final dispatcher = CapabilityDispatcher(container.read(Provider((ref) => settingsCapabilities(ref))));
    final context = RequestContext(Origin.palette);
    final before = await dispatcher.dispatch('settings.get', {}, context) as Ok<Object?>;
    final envelope = before.value as Map<String, Object?>;
    final revision = envelope['revision']! as int;
    expect((envelope['settings']! as Map)['themeMode'], 'system');
    expect(
      await dispatcher.dispatch('settings.patch', {'themeMode': 'dark', 'expectedRevision': revision}, context),
      isA<Ok<Object?>>(),
    );
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
    final after = await dispatcher.dispatch('settings.get', {}, context) as Ok<Object?>;
    expect((after.value as Map)['revision'], revision + 1);
    await expectLater(
      dispatcher.dispatch('settings.patch', {'themeMode': 'light', 'expectedRevision': revision}, context),
      throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
    );
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
  });
}
