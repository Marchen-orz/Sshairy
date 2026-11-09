import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/adapters/ssh_exec.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/foundation/cancellation.dart';

/// Exercises the installed SSH session/channel implementation without a socket or server.
class _Peer {
  _Peer(this.id, {bool outputFailure = false, bool deferredSession = false}) {
    channel = SSHChannelController(
      localId: id,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 1 << 20,
      remoteId: id + 100,
      remoteInitialWindowSize: 1 << 20,
      remoteMaximumPacketSize: 32768,
      sendMessage: sent.add,
    );
    if (!deferredSession) {
      session = outputFailure ? _OutputFailureSession(channel.channel) : SSHSession(channel.channel);
    }
  }

  final int id;
  final sent = <SSHMessage>[];
  late final SSHChannelController channel;
  late final SSHSession session;

  int get closes => sent.whereType<SSH_Message_Channel_Close>().length;

  void data(String text, {bool stderr = false}) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    channel.handleMessage(
      stderr
          ? SSH_Message_Channel_Extended_Data(recipientChannel: id, dataTypeCode: 1, data: bytes)
          : SSH_Message_Channel_Data(recipientChannel: id, data: bytes),
    );
  }

  void finish([int? exitCode = 0]) {
    if (exitCode != null) {
      channel.handleMessage(SSH_Message_Channel_Request.exitStatus(recipientChannel: id, exitStatus: exitCode));
    }
    channel.handleMessage(SSH_Message_Channel_EOF(recipientChannel: id));
    channel.handleMessage(SSH_Message_Channel_Close(recipientChannel: id));
  }
}

class _OutputFailureSession extends SSHSession {
  _OutputFailureSession(super.channel);

  @override
  Stream<Uint8List> get stdout => Stream<Uint8List>.error(StateError('output failed'));
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher _fails(ExecFailure kind) => throwsA(isA<ExecError>().having((error) => error.kind, 'kind', kind));

void main() {
  final peers = <_Peer>[];
  _Peer peer() {
    final value = _Peer(peers.length);
    peers.add(value);
    return value;
  }

  tearDown(() async {
    for (final value in peers) {
      value.channel.channel.destroy();
    }
    await _settle();
    peers.clear();
  });

  test('legacy outer timeout leaves a real SSH execution open until the peer eventually ends it', () async {
    final value = peer();
    var closed = false;
    unawaited(value.session.done.then((_) => closed = true));
    Future<ExecResult> legacyCollect() async {
      final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
      await Future.wait([value.session.stdout.forEach(out.add), value.session.stderr.forEach(err.add)]);
      await value.session.done;
      return ExecResult(out.takeBytes(), err.takeBytes(), value.session.exitCode);
    }

    final running = legacyCollect();
    await expectLater(running.timeout(const Duration(milliseconds: 10)), throwsA(isA<TimeoutException>()));
    expect(value.closes, 0, reason: 'the old timeout only stopped waiting');
    expect(closed, isFalse);
    value.finish();
    await running;
    expect(value.closes, 1);
  });

  test('returns complete bounded streams and keeps missing exit status distinct from zero', () async {
    for (final code in <int?>[0, 7, null]) {
      final value = peer();
      final result = runSshExec(() async => value.session, limit: 4);
      await _settle();
      value.data('abcdef');
      value.data('uvwxyz', stderr: true);
      value.data('more output');
      value.finish(code);
      final output = await result;
      expect(utf8.decode(output.stdout), 'abcd');
      expect(utf8.decode(output.stderr), 'uvwx');
      expect(output.exitCode, code);
      expect(output.truncated, isTrue);
      expect(value.closes, 1);
    }
  });

  test('zero output budget still drains both streams and does not invent output', () async {
    final value = peer();
    final result = runSshExec(() async => value.session, limit: 0);
    await _settle();
    value.data('out');
    value.data('err', stderr: true);
    value.finish();
    final output = await result;
    expect(output.stdout, isEmpty);
    expect(output.stderr, isEmpty);
    expect(output.truncated, isTrue);
    expect(output.exitCode, 0);
  });

  test('pre-cancelled and zero-timeout calls do not start opening a channel', () async {
    var opens = 0;
    Future<SSHSession> open() async {
      opens++;
      return peer().session;
    }

    final cancel = CancellationToken()..cancel();
    await expectLater(runSshExec(open, cancel: cancel), _fails(ExecFailure.cancelled));
    await expectLater(runSshExec(open, timeout: Duration.zero), _fails(ExecFailure.timedOut));
    expect(opens, 0);
  });

  test('cancelling a running session sends one close and leaves another execution usable', () async {
    final first = peer(), other = peer();
    final cancel = CancellationToken();
    final stopped = runSshExec(() async => first.session, cancel: cancel);
    final survivor = runSshExec(() async => other.session);
    final failure = expectLater(stopped, _fails(ExecFailure.cancelled));
    await _settle();
    first.data('partial');
    cancel.cancel();
    cancel.cancel();
    await failure;
    await first.session.done;
    expect(first.closes, 1);
    expect(other.closes, 0);
    other.data('alive');
    other.finish();
    expect(utf8.decode((await survivor).stdout), 'alive');
    expect(other.closes, 1);
  });

  test('a timeout closes a running channel without returning partial success', () async {
    final value = peer();
    final result = runSshExec(() async => value.session, timeout: const Duration(milliseconds: 20));
    final failure = expectLater(result, _fails(ExecFailure.timedOut));
    await _settle();
    value.data('partial');
    await failure;
    await value.session.done;
    expect(value.closes, 1);
    expect(value.sent.whereType<SSH_Message_Channel_EOF>(), hasLength(1));
  });

  test('cancellation while opening closes the late session as soon as it arrives', () async {
    final opening = Completer<SSHSession>();
    final cancel = CancellationToken();
    final result = runSshExec(() => opening.future, cancel: cancel);
    final failure = expectLater(result, _fails(ExecFailure.cancelled));
    cancel.cancel();
    await failure;
    final late = peer();
    opening.complete(late.session);
    await _settle();
    expect(late.closes, 1);
    await late.session.done;
  });

  test('timeout includes opening and receives a late opening error without an unhandled error', () async {
    final opening = Completer<SSHSession>();
    await expectLater(
      runSshExec(() => opening.future, timeout: const Duration(milliseconds: 10)),
      _fails(ExecFailure.timedOut),
    );
    opening.completeError(StateError('late opening failed'));
    await _settle();
  });

  test('normal completion wins before later cancellation or timeout', () async {
    final value = peer();
    final cancel = CancellationToken();
    final result = runSshExec(() async => value.session, cancel: cancel, timeout: const Duration(milliseconds: 30));
    await _settle();
    value.data('done');
    value.finish();
    expect(utf8.decode((await result).stdout), 'done');
    cancel.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(value.closes, 1);
  });

  test('success waits for channel close even after both output streams reach EOF', () async {
    final value = peer();
    final result = runSshExec(() async => value.session, timeout: const Duration(milliseconds: 20));
    final failure = expectLater(result, _fails(ExecFailure.timedOut));
    await _settle();
    value.channel.handleMessage(SSH_Message_Channel_EOF(recipientChannel: value.id));
    await failure;
    expect(value.closes, 1);
  });

  test('repeated cancelled sessions finish and cannot keep old executions alive', () async {
    for (var i = 0; i < 20; i++) {
      final value = peer();
      final cancel = CancellationToken();
      final result = runSshExec(() async => value.session, cancel: cancel);
      final failure = expectLater(result, _fails(ExecFailure.cancelled));
      await _settle();
      cancel.cancel();
      await failure;
      await value.session.done;
      expect(value.closes, 1);
    }
  });

  test('an asynchronous opening error keeps its identity and clears cancellation and timeout work', () async {
    final opening = Completer<SSHSession>();
    final error = StateError('opening failed');
    final cancel = CancellationToken();
    final result = runSshExec(() => opening.future, cancel: cancel, timeout: const Duration(milliseconds: 20));
    final failure = expectLater(result, throwsA(same(error)));
    opening.completeError(error);
    await failure;
    cancel.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });

  test('an opening future created inside the adapter keeps its asynchronous error identity', () async {
    final error = StateError('internal opening failed');
    await expectLater(runSshExec(() async => throw error), throwsA(same(error)));
  });

  test('cancellation receives a late caller-owned opening error without changing the result', () async {
    final opening = Completer<SSHSession>();
    final cancel = CancellationToken();
    final result = runSshExec(() => opening.future, cancel: cancel);
    final failure = expectLater(result, _fails(ExecFailure.cancelled));
    cancel.cancel();
    await failure;
    opening.completeError(StateError('late cancelled opening failed'));
    await _settle();
    await expectLater(result, _fails(ExecFailure.cancelled));
  });

  test('an output error closes the actual channel without converting failure to success', () async {
    // The real channel handles cleanup; only the failing output source is injected.
    final broken = _Peer(peers.length, outputFailure: true);
    peers.add(broken);
    await expectLater(runSshExec(() async => broken.session), throwsStateError);
    await broken.session.done;
    expect(broken.closes, 1);
  });

  test('a real channel packet error fails execution instead of escaping or returning partial output', () async {
    final value = _Peer(peers.length, deferredSession: true);
    peers.add(value);
    final execution = runSshExec(() async => value.session = SSHSession(value.channel.channel));
    final failure = expectLater(execution, throwsA(isA<SSHStateError>()));
    await _settle();
    value.data('partial');
    value.channel.handleMessage(SSH_Message_Channel_Data(recipientChannel: value.id, data: Uint8List(32769)));
    await failure;
    await value.session.done;
    expect(value.closes, 1);
  });

  test('a late internal channel error cannot replace an already cancelled result', () async {
    final value = _Peer(peers.length, deferredSession: true);
    peers.add(value);
    final opening = Completer<SSHSession>();
    final cancel = CancellationToken();
    final execution = runSshExec(() {
      value.session = SSHSession(value.channel.channel);
      return opening.future;
    }, cancel: cancel);
    final failure = expectLater(execution, _fails(ExecFailure.cancelled));
    await _settle();
    cancel.cancel();
    await failure;
    value.channel.handleMessage(SSH_Message_Channel_Data(recipientChannel: value.id, data: Uint8List(32769)));
    opening.complete(value.session);
    await _settle();
    await expectLater(execution, _fails(ExecFailure.cancelled));
    expect(value.closes, 1);
  });

  test('invalid budgets and synchronous open errors are reported without leaking timers', () async {
    Future<SSHSession> open() => throw StateError('opening failed');
    await expectLater(runSshExec(open), throwsStateError);
    await expectLater(runSshExec(open, limit: -1), throwsArgumentError);
    await expectLater(runSshExec(open, timeout: const Duration(milliseconds: -1)), throwsArgumentError);
  });
}
