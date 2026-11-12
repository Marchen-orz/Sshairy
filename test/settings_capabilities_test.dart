import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/capabilities/settings.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/l10n/app_localizations.dart';
import 'package:sshairy/foundation/result.dart';

class _Gate implements AgentAuthority {
  final decision = Completer<bool>();
  var asked = false;
  @override
  Future<Result<void>> authorize(Capability capability, Map<String, Object?> args, RequestContext context) async {
    asked = true;
    return await decision.future ? const Ok(null) : const Err(AppError('denied'));
  }

  @override
  Future<Result<void>> revalidate(Capability capability, Map<String, Object?> args, RequestContext context) async =>
      const Ok(null);
}

void main() {
  for (final allow in [false, true]) {
    test('real Agent settings schema reaches approval and applies only after allow=$allow', () async {
      final dir = Directory.systemTemp.createTempSync('sshairy-settings-gate-');
      final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      addTearDown(() {
        container.dispose();
        dir.deleteSync(recursive: true);
      });
      final dispatcher = CapabilityDispatcher(container.read(Provider((ref) => settingsCapabilities(ref))));
      final gate = _Gate();
      final patch = dispatcher.dispatch('settings.patch', {
        'accent': 'green',
        'expectedRevision': 0,
      }, RequestContext(Origin.agent, authority: gate));
      await Future<void>.delayed(Duration.zero);
      expect(gate.asked, isTrue);
      expect(container.read(settingsProvider).accent, Accent.blue);
      gate.decision.complete(allow);
      expect(await patch, allow ? isA<Ok<Object?>>() : isA<Err<Object?>>());
      expect(container.read(settingsProvider).accent, allow ? Accent.green : Accent.blue);
      expect(
        await dispatcher.dispatch('settings.patch', {'accent': 'green'}, RequestContext(Origin.agent, authority: gate)),
        isA<Err<Object?>>().having((e) => e.error.code, 'code', 'invalidArgument'),
      );
      expect(
        await dispatcher.dispatch('settings.patch', {
          'confirmPaste': false,
          'expectedRevision': 0,
        }, RequestContext(Origin.agent, authority: gate)),
        isA<Err<Object?>>().having((e) => e.error.code, 'code', 'invalidArgument'),
      );
    });
  }
  test('approval cannot overwrite settings edited while it was pending', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-settings-conflict-');
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });
    final dispatcher = CapabilityDispatcher(container.read(Provider((ref) => settingsCapabilities(ref))));
    final gate = _Gate();
    final patch = dispatcher.dispatch('settings.patch', {
      'accent': 'green',
      'expectedRevision': 0,
    }, RequestContext(Origin.agent, authority: gate));
    await Future<void>.delayed(Duration.zero);
    await container.read(settingsProvider.notifier).patch({'accent': 'orange'});
    gate.decision.complete(true);
    expect(await patch, isA<Err<Object?>>().having((e) => e.error.code, 'code', 'conflict'));
    expect(container.read(settingsProvider).accent, Accent.orange);
  });
  test('exposed settings describe the same names and choices as the UI in both languages', () {
    for (final language in ['zh', 'en']) {
      final l = lookupAppLocalizations(Locale(language));
      final accent = settingDescription(SettingKeys.accent, l);
      expect(accent['label'], l.accent);
      expect((accent['options'] as List).first, {'value': 'blue', 'label': l.themeNameBlue});
      expect((accent['options'] as List).length, Accent.values.length);
      expect(settingDescription(SettingKeys.fontSize, l)['label'], l.fontSize);
      expect(settingDescription(SettingKeys.uiFontSize, l)['label'], l.uiFontSize);
      expect(settingDescription(SettingKeys.uiScale, l)['description'], contains('125%'));
      for (final definition in SettingKeys.all.where((d) => d.agentExposed)) {
        expect(settingDescription(definition, l)['label'], isNot(definition.key), reason: definition.key);
      }
    }
  });
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
    expect(
      await dispatcher.dispatch('settings.patch', {'themeMode': 'light', 'expectedRevision': revision}, context),
      isA<Err<Object?>>().having((e) => e.error.code, 'code', 'conflict'),
    );
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
  });
}
