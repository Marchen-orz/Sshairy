import 'dart:async';
import 'dart:typed_data';

/// Abstract binary message transport beneath Sshairy Link's end-to-end encrypted session (docs/MOBILE.md §4.1).
///
/// Both direct LAN/Tailscale WebSocket connections and future zero-knowledge relay transports implement this interface
/// without exposing plaintext to the transport layer.
abstract interface class LinkTransport {
  Stream<Uint8List> get messages;
  Future<void> get done;
  bool get isClosed;
  String get remoteLabel;

  Future<void> send(Uint8List frame);
  Future<void> close();
}

/// Accepts incoming [LinkTransport] connections (direct WebSocket server or future relay client listener).
abstract interface class LinkListener {
  Stream<LinkTransport> get connections;
  int get port;
  Future<void> close();
}
