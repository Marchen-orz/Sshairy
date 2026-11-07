import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/adapters/terminal_output.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

class _Shell implements ShellChannel {
  final out = StreamController<Uint8List>(sync: true);
  final err = StreamController<Uint8List>(sync: true);
  final ended = Completer<void>();
  bool delayClose = false;
  int closes = 0;

  @override
  Stream<Uint8List> get stdout => out.stream;
  @override
  Stream<Uint8List> get stderr => err.stream;
  @override
  Future<void> get done => ended.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    closes++;
    if (delayClose) return;
    finish();
  }

  void finish() {
    if (!ended.isCompleted) ended.complete();
    unawaited(out.close());
    unawaited(err.close());
  }
}

class _Transport extends FakeTransport {
  final opened = <_Shell>[];
  @override
  Future<ShellChannel> openShell({
    required int cols,
    required int rows,
    Map<String, String> environment = const {},
  }) async {
    final shell = _Shell();
    opened.add(shell);
    return shell;
  }
}

void main() {
  group('TerminalOutput', () {
    test('pauses both streams at high water and resumes them below low water', () async {
      final pauses = [0, 0], resumes = [0, 0];
      final resumed = [Completer<void>(), Completer<void>()];
      final sources = [
        for (var i = 0; i < 2; i++)
          StreamController<Uint8List>(
            sync: true,
            onPause: () => pauses[i]++,
            onResume: () {
              resumes[i]++;
              resumed[i].complete();
            },
          ),
      ];
      var written = 0;
      final output = TerminalOutput(sources.map((s) => s.stream).toList(), (s) => written += s.length);
      addTearDown(output.cancel);
      final bytes = Uint8List(TerminalOutput.highWater + 1)..fillRange(0, TerminalOutput.highWater + 1, 65);
      sources.first.add(bytes);
      expect(output.pendingBytes, bytes.length);
      await Future<void>.value();
      expect(pauses, [1, 1]);
      expect(sources.map((s) => s.isPaused), [true, true]);
      await Future.wait(resumed.map((c) => c.future)).timeout(const Duration(seconds: 5));
      expect(output.pendingBytes, lessThanOrEqualTo(TerminalOutput.lowWater));
      unawaited(sources.first.close());
      unawaited(sources.last.close());
      await output.done.timeout(const Duration(seconds: 5));
      expect(written, bytes.length);
      expect(resumes, [1, 1]);
      expect(output.pendingBytes, 0);
      expect(output.error, isNull);
    });

    test('large events yield to the event queue after a bounded parse turn', () async {
      final source = StreamController<Uint8List>(sync: true);
      var parsed = 0;
      final output = TerminalOutput([source.stream], (text) => parsed += text.length);
      addTearDown(output.cancel);
      final count = TerminalOutput.turnBytes * 3;
      source.add(Uint8List(count)..fillRange(0, count, 65));
      final firstTurn = Completer<int>();
      Timer(Duration.zero, () => firstTurn.complete(parsed));
      unawaited(source.close());
      expect(await firstTurn.future, inInclusiveRange(1, TerminalOutput.turnBytes));
      await output.done.timeout(const Duration(seconds: 5));
      expect(parsed, count);
    });

    test('queue buffers release consumed prefixes and do not retain a larger input backing buffer', () async {
      final source = StreamController<Uint8List>(sync: true);
      final backing = Uint8List(TerminalOutput.highWater * 8);
      final bytes = Uint8List.sublistView(backing, 123, 123 + TerminalOutput.highWater + 1)
        ..fillRange(0, TerminalOutput.highWater + 1, 65);
      final text = StringBuffer();
      final output = TerminalOutput([source.stream], text.write);
      addTearDown(output.cancel);
      source.add(bytes);
      expect(output.pendingBytes, bytes.length);
      expect(
        output.retainedBytes,
        bytes.length,
        reason: 'the queue owns only the event payload, not its 8 MiB backing',
      );
      bytes.fillRange(0, bytes.length, 66);
      final firstTurn = Completer<(int, int)>();
      Timer(Duration.zero, () => firstTurn.complete((output.pendingBytes, output.retainedBytes)));
      final (pending, retained) = await firstTurn.future;
      expect(pending, inExclusiveRange(0, bytes.length));
      expect(retained, pending, reason: 'consumed blocks no longer retain a prefix of the original input');
      unawaited(source.close());
      await output.done.timeout(const Duration(seconds: 5));
      expect(output.retainedBytes, 0);
      expect(text.toString(), 'A' * bytes.length, reason: 'later upstream mutations cannot alter queued output');
    });

    test('lost input drains accepted bytes and closes decoders without waiting for stream EOF', () async {
      final out = StreamController<Uint8List>(sync: true);
      final err = StreamController<Uint8List>(sync: true);
      final text = StringBuffer();
      final output = TerminalOutput([out.stream, err.stream], text.write);
      out.add(utf8.encode('tail'));
      err.add(Uint8List.fromList([0xf0]));
      output.finishInput();
      output.finishInput();
      await output.done.timeout(const Duration(seconds: 5));
      expect(text.toString(), 'tail�');
      expect(out.hasListener, isFalse);
      expect(err.hasListener, isFalse);
      expect(output.error, isNull);
      await out.close();
      await err.close();
    });

    test('UTF-8 and control sequences survive arbitrary event and slice boundaries', () async {
      final source = StreamController<Uint8List>(sync: true);
      final text = '${'a' * (TerminalOutput.sliceBytes - 2)}\x1b[31m中🙂\x1b[0m';
      final written = StringBuffer();
      final output = TerminalOutput([source.stream], written.write);
      addTearDown(output.cancel);
      final bytes = utf8.encode(text);
      source.add(Uint8List.sublistView(bytes, 0, TerminalOutput.sliceBytes + 4));
      for (var i = TerminalOutput.sliceBytes + 4; i < bytes.length; i++) {
        source.add(Uint8List.sublistView(bytes, i, i + 1));
      }
      unawaited(source.close());
      await output.done.timeout(const Duration(seconds: 5));
      expect(written.toString(), text);
    });

    test('stdout and stderr maintain separate incremental decoders', () async {
      final out = StreamController<Uint8List>(sync: true);
      final err = StreamController<Uint8List>(sync: true);
      final written = StringBuffer();
      final output = TerminalOutput([out.stream, err.stream], written.write);
      addTearDown(output.cancel);
      final a = utf8.encode('中'), b = utf8.encode('文');
      out.add(Uint8List.sublistView(a, 0, 1));
      err.add(Uint8List.sublistView(b, 0, 2));
      out.add(Uint8List.sublistView(a, 1));
      err.add(Uint8List.sublistView(b, 2));
      out.add(Uint8List.fromList([0xf0]));
      unawaited(out.close());
      unawaited(err.close());
      await output.done.timeout(const Duration(seconds: 5));
      expect(written.toString(), '中文�', reason: 'only the deliberately incomplete final sequence is malformed');
    });

    test('cancellation discards pending bytes and cancels subscriptions', () async {
      var cancelled = false;
      final source = StreamController<Uint8List>(sync: true, onCancel: () => cancelled = true);
      final text = StringBuffer();
      final output = TerminalOutput([source.stream], text.write);
      source.add(utf8.encode('queued'));
      output.cancel();
      await output.done;
      await pumpEventQueue();
      expect(cancelled, isTrue);
      expect(output.pendingBytes, 0);
      expect(text.isEmpty, isTrue);
      await source.close();
    });

    test('stream failures finish and discard remaining output without unhandled errors', () async {
      final source = StreamController<Uint8List>(sync: true);
      final text = StringBuffer();
      final output = TerminalOutput([source.stream], text.write);
      final problem = StateError('closed');
      source.add(utf8.encode('queued'));
      source.addError(problem);
      await output.failed;
      await output.done;
      expect(output.error, same(problem));
      expect(text.isEmpty, isTrue);
      expect(output.pendingBytes, 0);
      await source.close();
    });
  });

  group('TerminalSession output lifecycle', () {
    late _Transport transport;
    late ConnectionManager manager;
    late TerminalSession session;

    Future<void> connected() async {
      unawaited(session.connect(NoPrompts()));
      await pumpEventQueue();
      expect(session.status, SessionStatus.connected);
    }

    setUp(() {
      transport = _Transport();
      manager = ConnectionManager((_, _, _) async => transport);
      session = TerminalSession(
        const SessionId('flow'),
        const Host(id: HostId('host'), label: 'host', address: 'host', username: 'u'),
        manager,
      );
    });
    tearDown(() async {
      session.close();
      for (final shell in transport.opened) {
        shell.finish();
      }
      manager.closeAll();
      await pumpEventQueue();
    });

    test('shell done waits for the queued tail, even with no visible view', () async {
      await connected();
      final shell = transport.opened.single;
      shell.ended.complete();
      await pumpEventQueue();
      expect(session.status, SessionStatus.connected, reason: 'the byte streams have not ended yet');
      expect(session.canInsert, isFalse);
      expect(session.unread, isFalse);
      shell.out.add(utf8.encode('final output'));
      shell.finish();
      await pumpEventQueue();
      expect(session.unread, isTrue);
      expect(session.status, SessionStatus.disconnected);
    });

    test('a lost transport reconnects even when its shell and byte streams never finish', () async {
      session.close();
      session = TerminalSession(
        const SessionId('lost-transport'),
        const Host(id: HostId('host'), label: 'host', address: 'host', username: 'u'),
        manager,
        autoReconnect: () => true,
      );
      await connected();
      final lostTransport = transport;
      final old = lostTransport.opened.single..delayClose = true;
      old.out.add(utf8.encode('accepted tail'));
      lostTransport.close();
      await pumpEventQueue();
      expect(session.status, SessionStatus.disconnected);
      expect(session.unread, isTrue);
      expect(session.reconnectIn, isNotNull);
      expect(old.ended.isCompleted, isFalse, reason: 'transport loss does not depend on shell.done');
      expect(old.out.hasListener, isFalse);
      expect(old.err.hasListener, isFalse);
      expect(old.closes, greaterThan(0));
      transport = _Transport();
      for (var i = 0; i < 40 && session.status != SessionStatus.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(session.status, SessionStatus.connected);
      expect(transport.opened, hasLength(1));
      expect(session.canInsert, isTrue);
      old.finish();
    });

    test('transport loss also ends a tail drain already waiting after shell.done', () async {
      await connected();
      final shell = transport.opened.single..delayClose = true;
      shell.ended.complete();
      await pumpEventQueue();
      expect(session.status, SessionStatus.connected);
      transport.close();
      await pumpEventQueue();
      expect(session.status, SessionStatus.disconnected);
      expect(shell.out.hasListener, isFalse);
      expect(shell.err.hasListener, isFalse);
      shell.finish();
    });

    test('late completion and output from an old shell cannot change a new shell', () async {
      await connected();
      final old = transport.opened.single..delayClose = true;
      old.out.addError(StateError('stream failed'));
      await pumpEventQueue();
      expect(session.status, SessionStatus.failed);
      await connected();
      expect(session.canInsert, isTrue);
      old.ended.complete();
      old.out.add(utf8.encode('stale'));
      await pumpEventQueue();
      expect(session.canInsert, isTrue);
      expect(session.unread, isFalse);
      transport.opened.last.out.add(utf8.encode('current'));
      await pumpEventQueue();
      expect(session.unread, isTrue);
    });

    test('closing with queued output cancels it without notifying a disposed session', () async {
      await connected();
      var notifications = 0;
      session.addListener(() => notifications++);
      transport.opened.single.out.add(Uint8List(TerminalOutput.highWater));
      session.close();
      final atClose = notifications;
      await pumpEventQueue();
      expect(notifications, atClose);
      expect(session.unread, isFalse);
    });

    test('closing while dialing cancels the connection wait', () async {
      session.close();
      manager.closeAll();
      final cancelled = Completer<void>();
      final dialled = Completer<void>();
      manager = ConnectionManager((_, _, cancel) async {
        cancel.whenCancelled.then((_) => cancelled.complete());
        dialled.complete();
        await cancel.whenCancelled;
        throw const ConnectError(ConnectFailure.cancelled);
      });
      session = TerminalSession(
        const SessionId('dialling'),
        const Host(id: HostId('host'), label: 'host', address: 'host', username: 'u'),
        manager,
      );
      final connecting = session.connect(NoPrompts());
      await dialled.future;
      session.close();
      await cancelled.future.timeout(const Duration(seconds: 5));
      await connecting;
    });
  });
}
