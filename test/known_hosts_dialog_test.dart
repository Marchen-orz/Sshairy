import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/application/host_trust.dart';
import 'package:sshairy/features/connections/domain/known_hosts.dart';
import 'package:sshairy/features/connections/presentation/known_hosts_dialog.dart';
import 'package:sshairy/l10n/app_localizations.dart';

const _fp = 'SHA256:BcOA1e/c6N/nOjjNppHjb6NakRUZxtGklHFoRcaHwgI';

const _preview = KnownHostsPreview(
  additions: [KnownHostsCandidate(2, 'new.example.org:22', 'ssh-ed25519', _fp)],
  alreadyTrusted: [KnownHostsCandidate(3, 'same.example.org:22', 'ssh-ed25519', _fp)],
  conflicts: [KnownHostsConflict(4, 'changed.example.org:22', 'ssh-ed25519', _fp, 'SHA256:saved')],
  issues: [
    KnownHostsIssueEntry(5, KnownHostsIssue.marker, '@revoked'),
    KnownHostsIssueEntry(6, KnownHostsIssue.wildcard, '*.example.org'),
  ],
);

Future<void> _open(
  WidgetTester tester,
  KnownHostsPreview preview,
  Future<TrustImportResult> Function() commit,
  List<Object?> popped,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => popped.add(
            await showDialog<TrustImportResult>(
              context: context,
              builder: (_) => KnownHostsImportDialog(preview: preview, commit: commit),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists what would change and saves only on Import', (tester) async {
    var commits = 0;
    final popped = <Object?>[];
    await _open(tester, _preview, () async {
      commits++;
      return const TrustImportResult(added: 1);
    }, popped);

    expect(find.text('New keys'), findsOneWidget);
    expect(find.text('Already trusted'), findsOneWidget);
    expect(find.text('Differs from saved key, left unchanged'), findsOneWidget);
    expect(find.text('Not imported'), findsOneWidget);
    expect(find.text('changed.example.org:22 · ssh-ed25519'), findsOneWidget);
    expect(find.textContaining('SHA256:saved'), findsOneWidget);
    expect(find.text('Marker not supported'), findsOneWidget);
    expect(find.textContaining('@revoked'), findsOneWidget);
    expect(find.text('new.example.org:22 · ssh-ed25519'), findsOneWidget);
    expect(commits, 0);

    await tester.tap(find.text('Import 1'));
    await tester.pumpAndSettle();
    expect(commits, 1);
    expect((popped.single as TrustImportResult).added, 1);
  });

  testWidgets('Cancel saves nothing, and there is nothing to import without a new key', (tester) async {
    var commits = 0;
    final popped = <Object?>[];
    await _open(tester, _preview, () async => TrustImportResult(added: ++commits), popped);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(commits, 0);
    expect(popped, [null]);

    await _open(tester, const KnownHostsPreview(), () async => TrustImportResult(added: ++commits), popped);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('a failed save keeps the dialog open and says so', (tester) async {
    final popped = <Object?>[];
    await _open(tester, _preview, () async => throw StateError('disk'), popped);
    await tester.tap(find.text('Import 1'));
    await tester.pumpAndSettle();
    expect(find.text('Could not save the trusted keys'), findsOneWidget);
    expect(popped, isEmpty);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('a large file does not build every row', (tester) async {
    final many = KnownHostsPreview(
      additions: [for (var i = 0; i < 5000; i++) KnownHostsCandidate(i + 1, 'h$i.example.org:22', 'ssh-ed25519', _fp)],
    );
    await _open(tester, many, () async => const TrustImportResult(), []);
    expect(find.text('Import 5000'), findsOneWidget);
    expect(find.textContaining('.example.org:22 · ssh-ed25519').evaluate().length, lessThan(30));
  });
}
