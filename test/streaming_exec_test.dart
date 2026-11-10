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

class _Peer {
  _Peer(this.id) {
    channel = SSHChannelController(
      localId: id,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 1 << 20,
      remoteId: id + 100,
      remoteInitialWindowSize: 1 << 20,
      remoteMaximumPacketSize: 32768,
      sendMessage: sent.add,
    );
    session = SSHSession(channel.channel);
  }

  final int id;
  final sent = <SSHMessage>[];
  late final SSHChannelController channel;
  late final SSHSession session;
  int get closes => sent.whereType<SSH_Message_Channel_Close>().length;

  void data(String text, {bool stderr = false}) => bytes(Uint8List.fromList(utf8.encode(text)), stderr: stderr);

  void bytes(Uint8List data, {bool stderr = false}) {
    channel.handleMessage(
      stderr
          ? SSH_Message_Channel_Extended_Data(recipientChannel: id, dataTypeCode: 1, data: data)
          : SSH_Message_Channel_Data(recipientChannel: id, data: data),
    );
  }

  void finish([int? code = 0]) {
    if (code != null) {
      channel.handleMessage(SSH_Message_Channel_Request.exitStatus(recipientChannel: id, exitStatus: code));
    }
    channel.handleMessage(SSH_Message_Channel_EOF(recipientChannel: id));
    channel.handleMessage(SSH_Message_Channel_Close(recipientChannel: id));
  }
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

  test('streams bytes before exit and preserves each stream order and null exit status', () async {
    final value = peer();
    final chunks = <ExecChunk>[];
    var complete = false;
    final running = runSshExecStreaming(() async => value.session, onOutput: chunks.add);
    unawaited(running.then((_) => complete = true));
    await _settle();
    value.data('first');
    value.data('error one', stderr: true);
    value.data('second');
    await _settle();
    expect(complete, isFalse);
    expect(chunks.where((c) => c.stream == ExecStream.stdout).map((c) => utf8.decode(c.bytes)), ['first', 'second']);
    expect(chunks.where((c) => c.stream == ExecStream.stderr).map((c) => utf8.decode(c.bytes)), ['error one']);
    value.finish(null);
    expect(await running, isNull);
    expect(value.closes, 1);
  });

  test('stream callback owns bytes independent of the source packet buffer', () async {
    final value = peer();
    final chunks = <ExecChunk>[];
    final running = runSshExecStreaming(() async => value.session, onOutput: chunks.add);
    await _settle();
    final input = Uint8List.fromList([65, 66]);
    value.bytes(input);
    await _settle();
    input.fillRange(0, input.length, 0);
    expect(chunks.single.bytes, [65, 66]);
    value.finish();
    expect(await running, 0);
  });

  test('a bounded consumer may discard excess while the adapter drains both streams to exit', () async {
    final value = peer();
    var total = 0;
    final retained = BytesBuilder();
    final running = runSshExecStreaming(
      () async => value.session,
      onOutput: (chunk) {
        total += chunk.bytes.length;
        final room = 16 - retained.length;
        if (room > 0) retained.add(chunk.bytes.take(room).toList());
      },
    );
    await _settle();
    for (var i = 0; i < 200; i++) {
      value.data('a' * 4096, stderr: i.isOdd);
      if (i % 20 == 0) await _settle();
    }
    value.finish(7);
    expect(await running, 7);
    expect(total, 200 * 4096);
    expect(retained.length, 16);
    expect(value.closes, 1);
  });

  test('pre-cancelled and zero deadline streaming calls open no channel', () async {
    var opened = 0;
    Future<SSHSession> open() async {
      opened++;
      return peer().session;
    }

    final cancel = CancellationToken()..cancel();
    await expectLater(runSshExecStreaming(open, onOutput: (_) {}, cancel: cancel), _fails(ExecFailure.cancelled));
    await expectLater(
      runSshExecStreaming(open, onOutput: (_) {}, timeout: Duration.zero),
      _fails(ExecFailure.timedOut),
    );
    expect(opened, 0);
  });

  test('cancel closes only its streaming channel and stops further callback delivery', () async {
    final first = peer(), other = peer();
    final cancel = CancellationToken();
    final output = <ExecChunk>[];
    final stopped = runSshExecStreaming(() async => first.session, onOutput: output.add, cancel: cancel);
    final failure = expectLater(stopped, _fails(ExecFailure.cancelled));
    final survivor = runSshExecStreaming(() async => other.session, onOutput: (_) {});
    await _settle();
    first.data('partial');
    await _settle();
    expect(output, hasLength(1));
    cancel.cancel();
    await failure;
    expect(first.closes, 1);
    expect(other.closes, 0);
    first.data('late');
    await _settle();
    expect(output, hasLength(1));
    other.finish();
    expect(await survivor, 0);
  });

  test('opening cancellation destroys the late session and ignores late output', () async {
    final opening = Completer<SSHSession>();
    final cancel = CancellationToken();
    final chunks = <ExecChunk>[];
    final running = runSshExecStreaming(() => opening.future, onOutput: chunks.add, cancel: cancel);
    final failure = expectLater(running, _fails(ExecFailure.cancelled));
    cancel.cancel();
    await failure;
    final late = peer();
    opening.complete(late.session);
    await _settle();
    expect(late.closes, 1);
    expect(chunks, isEmpty);
  });

  test('timeout after output is an error and still waits for actual channel close on success', () async {
    final value = peer();
    final chunks = <ExecChunk>[];
    final running = runSshExecStreaming(
      () async => value.session,
      onOutput: chunks.add,
      timeout: const Duration(milliseconds: 20),
    );
    final failure = expectLater(running, _fails(ExecFailure.timedOut));
    await _settle();
    value.data('partial');
    value.channel.handleMessage(SSH_Message_Channel_EOF(recipientChannel: value.id));
    await failure;
    expect(chunks, hasLength(1));
    expect(value.closes, 1);
  });

  test('consumer failure closes the channel and preserves failure instead of partial success', () async {
    final value = peer();
    final failure = StateError('consumer failed');
    final running = runSshExecStreaming(() async => value.session, onOutput: (_) => throw failure);
    final expected = expectLater(running, throwsA(same(failure)));
    await _settle();
    value.data('output');
    await expected;
    expect(value.closes, 1);
  });
}
