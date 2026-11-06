import 'dart:async';
import 'dart:typed_data';

import '../../connections/api.dart';
import '../domain/forward.dart';
import '../domain/socks5.dart';
import 'runtime.dart';

/// How long the two sides get to close after both directions have ended.
const _closeGrace = Duration(seconds: 5);

/// Copies bytes both ways until both directions end, then waits (bounded) for both sides to close.
/// A failure in either direction destroys both at once. Each side's reads pause while the other is slow.
/// [localIn] replaces `local.stream` when the handshake already consumed it.
Future<void> relay(LocalConnection local, Tunnel tunnel, {Stream<Uint8List>? localIn}) async {
  void destroyBoth() {
    local.destroy();
    tunnel.destroy();
  }

  Future<void> pump(Stream<Uint8List> from, StreamSink<List<int>> to) async {
    try {
      await to.addStream(from.handleError((Object _) => destroyBoth()));
      // Half-close: data already queued still goes out, and the other direction keeps flowing.
      to.close().ignore();
    } on Object {
      destroyBoth();
    }
  }

  Future<void> settled(Future<void> f) => f.then((_) {}, onError: (Object _) {});

  final upstream = pump(localIn ?? local.stream, tunnel.sink);
  final downstream = pump(tunnel.stream, local.sink);
  final closed = Future.wait([settled(local.done), settled(tunnel.done)]);

  // The channel is gone, so the server can send nothing more: let what arrived reach the client, then hang up even
  // if the client keeps its side open.
  Future<void> hangUp() async {
    await settled(tunnel.done);
    await downstream;
    await settled(local.flush().timeout(_closeGrace));
  }

  await Future.any([
    closed,
    Future.wait([upstream, downstream]).then((_) => closed.timeout(_closeGrace, onTimeout: () => const [])),
    hangUp(),
  ]);
  destroyBoth();
}

/// Reads the client's SOCKS5 handshake from [local]. Besides the request it returns what the client sends after
/// it; that stream stays paused until somebody listens, so nothing is read ahead while the target is dialled.
/// Throws [ForwardError] (handshake or timeout); a refusal reply may already be queued on `local.sink`.
Future<(Socks5Request, Stream<Uint8List>)> socksNegotiate(LocalConnection local, Duration timeout) async {
  final handshake = Socks5Handshake();
  final negotiated = Completer<Socks5Request>();
  final rest = StreamController<Uint8List>(sync: true);

  void fail(Object error) {
    if (negotiated.isCompleted) {
      rest.addError(error);
    } else {
      negotiated.completeError(error);
    }
  }

  late final StreamSubscription<Uint8List> input;
  input = local.stream.listen(
    (data) {
      if (negotiated.isCompleted) return rest.add(data);
      try {
        final reply = handshake.feed(data);
        if (reply != null) local.sink.add(reply);
        final request = handshake.request;
        if (request == null) return;
        // Held until the relay listens to [rest], which starts the flow again.
        input.pause();
        if (handshake.rest.isNotEmpty) rest.add(handshake.rest);
        negotiated.complete(request);
      } on Socks5Error catch (e) {
        if (e.reply != null) local.sink.add(e.reply!);
        fail(const ForwardError(ForwardErrors.handshake));
      }
    },
    onError: fail,
    onDone: () {
      if (negotiated.isCompleted) {
        rest.close();
      } else {
        fail(const ForwardError(ForwardErrors.handshake));
      }
    },
  );
  rest
    ..onListen = input.resume
    ..onResume = input.resume
    ..onPause = input.pause
    ..onCancel = input.cancel;
  try {
    final request = await negotiated.future.timeout(
      timeout,
      onTimeout: () => throw const ForwardError(ForwardErrors.timeout),
    );
    return (request, rest.stream);
  } on Object {
    unawaited(input.cancel());
    rethrow;
  }
}
