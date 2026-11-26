import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/link/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _TestLinkCredentials implements LinkCredentials {
  Secret? _seed;

  @override
  Future<Secret?> readIdentity() async => _seed;

  @override
  Future<void> saveIdentity(Secret seed) async => _seed = seed;

  @override
  Future<void> clearIdentity() async => _seed = null;
}

class _NoLanScanLinkClient extends LinkClientController {
  _NoLanScanLinkClient({required super.credentials, required super.store, required super.bridge});

  @override
  Future<void> discoverLan() async {}
}

void main() {
  testWidgets('SliverReveal animates smoothly in full motion and snaps in light/off motion', (tester) async {
    var open = true;
    var level = MotionLevel.full;
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return MaterialApp(
            theme: buildTheme(Brightness.light),
            home: MotionScope(
              level: level,
              child: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    SliverReveal(
                      open: open,
                      sliver: const SliverToBoxAdapter(child: SizedBox(height: 120, child: Text('section-body'))),
                    ),
                    const SliverToBoxAdapter(child: Text('after-section')),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    expect(tester.getTopLeft(find.text('after-section')).dy, closeTo(120, .01));

    rebuild(() => open = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final midY = tester.getTopLeft(find.text('after-section')).dy;
    expect(midY, greaterThan(0));
    expect(midY, lessThan(120));
    expect(motionActivity.running, isTrue);

    // Reversing mid-collapse resumes from the current height rather than jumping.
    rebuild(() => open = true);
    await tester.pump();
    expect(tester.getTopLeft(find.text('after-section')).dy, closeTo(midY, 1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('after-section')).dy, closeTo(120, .01));
    expect(motionActivity.running, isFalse);

    // Light and off motion collapse immediately without intermediate frames.
    for (final instant in [MotionLevel.light, MotionLevel.off]) {
      rebuild(() => level = instant);
      await tester.pump();
      rebuild(() => open = false);
      await tester.pump();
      await tester.pump();
      expect(tester.getTopLeft(find.text('after-section')).dy, closeTo(0, .01));
      expect(find.text('section-body'), findsNothing);
      expect(motionActivity.running, isFalse);
      rebuild(() => open = true);
      await tester.pump();
      await tester.pump();
      expect(tester.getTopLeft(find.text('after-section')).dy, closeTo(120, .01));
    }
  });

  testWidgets('HostTree group collapse animates in full motion and snaps in off motion', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy_host_tree_motion_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final container = ProviderContainer(overrides: [...appOverrides(), dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container
          .read(hostsProvider.notifier)
          .save(const Host(id: HostId('h1'), label: 'prod-api', address: '10.0.0.1', username: 'ops', group: 'prod'));
      await container
          .read(hostsProvider.notifier)
          .save(const Host(id: HostId('h2'), label: 'standalone', address: '10.0.0.2', username: 'ops'));
    });

    var level = MotionLevel.full;
    late StateSetter rebuild;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return MaterialApp(
              theme: buildTheme(Brightness.light),
              locale: const Locale('en'),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              home: MotionScope(
                level: level,
                child: Scaffold(body: HostTree(onConnect: (_) {})),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final startY = tester.getTopLeft(find.text('standalone')).dy;
    await tester.tap(find.text('prod'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final midY = tester.getTopLeft(find.text('standalone')).dy;
    expect(midY, lessThan(startY));
    expect(find.text('prod-api'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('prod-api'), findsNothing);
    expect(tester.getTopLeft(find.text('standalone')).dy, lessThan(midY));

    // Re-open, switch to off motion, and collapse immediately.
    rebuild(() => level = MotionLevel.off);
    await tester.pump();
    await tester.tap(find.text('prod'));
    await tester.pump();
    await tester.pump();
    expect(find.text('prod-api'), findsOneWidget);
    await tester.tap(find.text('prod'));
    await tester.pump();
    await tester.pump();
    expect(find.text('prod-api'), findsNothing);
  });

  testWidgets('appPageRoute and showAppBottomSheet obey all three motion levels and track motionActivity', (
    tester,
  ) async {
    var level = MotionLevel.full;
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (context, child) => MotionScope(level: level, child: child ?? const SizedBox.shrink()),
            home: const Scaffold(body: Center(child: Text('home-page'))),
          );
        },
      ),
    );

    BuildContext homeContext() => tester.element(find.text('home-page'));
    NavigatorState nav() => tester.state<NavigatorState>(find.byType(Navigator));

    // Full motion: page route animates fade + shift and marks motionActivity running.
    nav().push<void>(
      appPageRoute<void>(
        homeContext(),
        builder: (_) => const Scaffold(body: Center(child: Text('detail-page'))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(motionActivity.running, isTrue);
    expect(find.ancestor(of: find.text('detail-page'), matching: find.byType(FractionalTranslation)), findsOneWidget);
    await tester.pumpAndSettle();
    expect(motionActivity.running, isFalse);
    nav().pop();
    await tester.pumpAndSettle();

    // Light motion: page route fades without FractionalTranslation shift.
    rebuild(() => level = MotionLevel.light);
    await tester.pump();
    nav().push<void>(
      appPageRoute<void>(
        homeContext(),
        builder: (_) => const Scaffold(body: Center(child: Text('light-page'))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(motionActivity.running, isTrue);
    expect(find.ancestor(of: find.text('light-page'), matching: find.byType(FractionalTranslation)), findsNothing);
    expect(find.ancestor(of: find.text('light-page'), matching: find.byType(Opacity)), findsOneWidget);
    await tester.pumpAndSettle();
    nav().pop();
    await tester.pumpAndSettle();

    // Off motion: page route and bottom sheet commit immediately with Duration.zero.
    rebuild(() => level = MotionLevel.off);
    await tester.pump();
    nav().push<void>(
      appPageRoute<void>(
        homeContext(),
        builder: (_) => const Scaffold(body: Center(child: Text('instant-page'))),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('instant-page'), findsOneWidget);
    expect(motionActivity.running, isFalse);
    nav().pop();
    await tester.pump();
    await tester.pump();

    showAppBottomSheet<void>(
      context: homeContext(),
      builder: (_) => const SizedBox(height: 120, child: Center(child: Text('instant-sheet'))),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('instant-sheet'), findsOneWidget);
    expect(motionActivity.running, isFalse);
    nav().pop();
    await tester.pumpAndSettle();

    // Full motion bottom sheet tracks motionActivity while opening.
    rebuild(() => level = MotionLevel.full);
    await tester.pump();
    showAppBottomSheet<void>(
      context: homeContext(),
      builder: (_) => const SizedBox(height: 120, child: Center(child: Text('full-sheet'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(motionActivity.running, isTrue);
    await tester.pumpAndSettle();
    expect(motionActivity.running, isFalse);
  });

  testWidgets('Android Me tab exposes 3-tier motion setting, persists it, and controls MobileWorkspace transitions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('sshairy_mobile_motion_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/settings.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'values': {'importOffered': true},
      }),
    );

    final container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        linkCredentialsProvider.overrideWithValue(_TestLinkCredentials()),
        linkClientControllerProvider.overrideWith((ref) {
          final client = _NoLanScanLinkClient(
            credentials: ref.read(linkCredentialsProvider),
            store: LinkPeerStore(ref.read(dataDirProvider)),
            bridge: ref.read(linkMobileBridgeProvider),
          );
          ref.onDispose(client.dispose);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            final settings = ref.watch(settingsProvider);
            return MaterialApp(
              theme: buildTheme(Brightness.light),
              locale: const Locale('en'),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MotionScope(level: settings.motion, child: child ?? const SizedBox.shrink()),
              home: const MobileWorkspace(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switching to Me under default Full motion fades smoothly via PageVisibility.
    final navBar = find.byKey(const ValueKey('mobile-bottom-nav'));
    await tester.tap(find.descendant(of: navBar, matching: find.text('Me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(motionActivity.running, isTrue);
    await tester.pumpAndSettle();
    expect(motionActivity.running, isFalse);

    final motionControl = find.byKey(const ValueKey('mobile-motion-setting'));
    expect(motionControl, findsOneWidget);
    expect(tester.widget(motionControl), isA<AppSegmented<MotionLevel>>());
    expect(find.descendant(of: motionControl, matching: find.text('Off')), findsOneWidget);
    expect(find.descendant(of: motionControl, matching: find.text('Light')), findsOneWidget);
    expect(find.descendant(of: motionControl, matching: find.text('Full')), findsOneWidget);

    Future<void> waitSaved() async {
      var done = false;
      container.read(settingsProvider.notifier).saved.then((_) => done = true);
      for (var i = 0; i < 100 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(done, isTrue);
    }

    await tester.tap(find.descendant(of: motionControl, matching: find.text('Light')));
    await waitSaved();
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).motion, MotionLevel.light);
    expect(Motion.levelOf(tester.element(motionControl)), MotionLevel.light);

    await tester.tap(find.descendant(of: motionControl, matching: find.text('Off')));
    await waitSaved();
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).motion, MotionLevel.off);
    expect(Motion.levelOf(tester.element(motionControl)), MotionLevel.off);
    final persisted = Settings.fromJson(
      (jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map).cast<String, Object?>(),
    );
    expect(persisted.motion, MotionLevel.off);

    // Under Off motion, switching tabs commits immediately without animating.
    await tester.tap(find.descendant(of: navBar, matching: find.text('Hosts')));
    await tester.pump();
    await tester.pump();
    expect(motionActivity.running, isFalse);
    expect(find.byKey(const ValueKey('mobile-hosts-tab')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
