import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/terminal/domain/keyword_highlight.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';
import 'package:xterm2/xterm.dart';

class _Channel implements ShellChannel {
  final _stdout = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();

  void emit(String text) => _stdout.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => _done.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
  }
}

List<(String, KeywordKind)> _found(KeywordHighlighter h, String text) => [
  for (final m in h.match(text)) (text.substring(m.start, m.end), m.kind),
];

void main() {
  test('built-in words match whole and in any case', () {
    final h = KeywordHighlighter();
    expect(_found(h, 'Build FAILED: 2 errors, 1 Warning'), [
      ('FAILED', KeywordKind.error),
      ('errors', KeywordKind.error),
      ('Warning', KeywordKind.warning),
    ]);
    expect(_found(h, '● nginx.service - active (running)'), [
      ('active', KeywordKind.success),
      ('running', KeywordKind.success),
    ]);
    // Parts of longer words are left alone.
    expect(_found(h, 'token booking terror_log errored'), isEmpty);
    expect(_found(h, '[OK] 连接超时，部署失败'), [
      ('OK', KeywordKind.success),
      ('超时', KeywordKind.warning),
      ('失败', KeywordKind.error),
    ]);
    expect(h.match('   '), isEmpty);
  });

  test('custom words win over built-in ones and keep their characters literal', () {
    final h = KeywordHighlighter(custom: 'error, prod-db；部署 a.b');
    expect(_found(h, 'error on prod-db, 部署 axb a.b'), [
      ('error', KeywordKind.custom),
      ('prod-db', KeywordKind.custom),
      ('部署', KeywordKind.custom),
      ('a.b', KeywordKind.custom),
    ]);
    expect(parseKeywords(' a,,b  a '), ['a', 'b']);
  });

  test('wide characters map text back to the columns they start in', () {
    final terminal = Terminal(maxLines: 10)..write('中文 error');
    final (text, columns) = keywordLineText(terminal.buffer.lines[0]);
    final at = text.indexOf('error');
    expect(text.substring(0, at + 5), '中文 error');
    expect(columns[0], 0);
    expect(columns[1], 2);
    expect(columns[at], 5);
  });

  testWidgets('TerminalPane tints keywords on the shell screen but not in full-screen programs', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-keywords-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = _Channel();
    final session = TerminalSession.remote(
      const SessionId('keywords'),
      const LinkTerminalTarget(
        peerId: 'd1',
        peerName: 'Desk',
        remoteId: 'r1',
        title: 'Demo',
        targetLabel: 'Demo',
        kind: LinkTerminalKind.mirror,
      ),
      (_, _) async => channel,
    );
    addTearDown(session.dispose);
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(container.dispose);
    const boundary = ValueKey('keywords');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildTheme(Brightness.dark, Accent.deepSea, 14, null, null),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 140,
              child: RepaintBoundary(key: boundary, child: TerminalPane(session, active: true)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final palette = Accent.deepSea.palette(Brightness.dark);
    final tint = Color.alphaBlend(palette.ansi[1].withValues(alpha: .28), palette.terminalBackground);
    Future<bool> tinted() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final render = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
      final pixels = (await tester.runAsync(() async {
        final image = await render.toImage();
        try {
          return await image.toByteData(format: ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      }))!;
      int channel(int argb, int shift) => argb >> shift & 0xFF;
      final want = tint.toARGB32();
      for (var offset = 0; offset < pixels.lengthInBytes; offset += 4) {
        final rgb = pixels.getUint32(offset) >> 8;
        if ([16, 8, 0].every((s) => (channel(rgb, s) - channel(want, s)).abs() <= 2)) return true;
      }
      return false;
    }

    channel.emit('build error\r\n');
    expect(await tinted(), isTrue);
    // vim, htop and the like switch to the alternate screen and color their own text.
    channel.emit('\x1b[?1049h\x1b[Hbuild error');
    expect(await tinted(), isFalse);
  });
}
