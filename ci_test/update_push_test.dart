import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/settings/application/update_download.dart';
import 'package:sshairy/features/settings/application/updates.dart';
import 'package:sshairy/features/settings/presentation/update_check.dart';
import 'package:sshairy/foundation/app_info.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Feed implements ReleaseSource {
  final releases = Completer<List<ReleaseNote>>();
  var requests = 0;

  @override
  Future<List<ReleaseNote>> fetch() {
    requests++;
    return releases.future;
  }
}

class _ControlledDownloader extends UpdateDownloader {
  final sent = Completer<bool>();
  final received = Completer<UpdateDownloadState>();
  AndroidUpdate? selected;

  @override
  Future<bool> downloadAndPush(
    PeerUpdate peer,
    AndroidUpdate update, {
    required PushPeerUpdate push,
    required CancellationToken cancellation,
    required void Function(UpdateDownloadState) onProgress,
  }) {
    selected = update;
    onProgress(const UpdateDownloadState(UpdateDownloadStatus.downloading, received: 25, total: 100));
    return sent.future;
  }

  @override
  Future<UpdateDownloadState> receive(IncomingUpdate incoming) => received.future;
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(
    locale: Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: StartupUpdatePrompt(child: Scaffold()),
  ),
);

void main() {
  testWidgets('desktop waits for the release feed and displays progress for the phone APK', (tester) async {
    final feed = _Feed();
    final updates = StreamController<PeerUpdate>();
    final downloader = _ControlledDownloader();
    final container = ProviderContainer(
      overrides: [
        releaseSourceProvider.overrideWithValue(feed),
        updateSuggestionsProvider.overrideWithValue(updates.stream),
        updatePushProvider.overrideWithValue((_, _, _, _, _) async => true),
        updateDownloaderProvider.overrideWithValue(() => downloader),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(updates.close);
    await tester.pumpWidget(_app(container));
    updates.add((
      deviceId: 'phone',
      name: 'Phone',
      version: '0.0.1',
      abis: const ['arm64-v8a', 'armeabi-v7a'],
      lifetime: CancellationToken(),
      requested: false,
    ));
    await tester.pump();
    expect(downloader.selected, isNull);
    const arm64 = ReleaseAsset(name: 'sshairy-$appVersion-android-arm64-v8a.apk', url: '', size: 100);
    feed.releases.complete(const [
      ReleaseNote(
        version: appVersion,
        title: 'Update',
        notes: '',
        url: '',
        assets: [
          ReleaseAsset(name: 'sshairy-$appVersion-android-armeabi-v7a.apk', url: '', size: 100),
          arm64,
          ReleaseAsset(name: 'SHA256SUMS', url: '', size: 90),
        ],
      ),
    ]);
    await tester.pumpAndSettle();
    expect(feed.requests, 1);
    await tester.tap(find.text('Download and push'));
    await tester.pump();
    expect(downloader.selected?.asset, arm64);
    expect(find.text('25%'), findsOneWidget);
    downloader.sent.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Update sent. Confirm installation on your phone.'), findsOneWidget);
  });

  testWidgets('phone prompts only once the pushed APK is saved and installs only on confirmation', (tester) async {
    const channel = MethodChannel('dev.sshairy.sshairy/mobile_platform');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'opened';
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final feed = _Feed()..releases.complete(const []);
    final updates = StreamController<IncomingUpdate>();
    final downloader = _ControlledDownloader();
    final container = ProviderContainer(
      overrides: [
        releaseSourceProvider.overrideWithValue(feed),
        updatePushesProvider.overrideWithValue(updates.stream),
        updateDownloaderProvider.overrideWithValue(() => downloader),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(updates.close);
    await tester.pumpWidget(_app(container));
    final receipts = <bool>[];
    updates.add((
      package: const AndroidUpdatePackage(version: '9.0.0', abi: 'arm64-v8a', size: 100),
      open: () => throw StateError('Receive uses the overridden downloader'),
      complete: (received) async => receipts.add(received),
    ));
    final install = find.text('Install update');
    await tester.pumpAndSettle();
    expect(install, findsNothing);
    expect(calls, isEmpty);
    expect(receipts, isEmpty);

    const path = '/updates/sshairy-9.0.0-android-arm64-v8a.apk';
    downloader.received.complete(const UpdateDownloadState(UpdateDownloadStatus.ready, path: path));
    await tester.pumpAndSettle();
    expect(install, findsOneWidget);
    expect(receipts, [true]);
    expect(feed.requests, 1);
    expect(calls, isEmpty);
    await tester.tap(install);
    await tester.pumpAndSettle();
    expect(calls.single.method, 'installUpdate');
    expect(calls.single.arguments, {'path': path, 'version': '9.0.0'});
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
