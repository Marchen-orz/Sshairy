import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ffi/ffi.dart';

/// Agent protocol message numbers (draft-miller-ssh-agent).
abstract final class AgentMessage {
  static const failure = 5,
      requestIdentities = 11,
      identitiesAnswer = 12,
      signRequest = 13,
      signResponse = 14,
      rsaSha256 = 2;
}

/// Frames larger than this are refused in either direction.
const agentFrameLimit = 256 * 1024;

/// The system's SSH agent (docs/DESIGN.md ADR-17). Every request opens its own connection, as the protocol allows, so
/// an agent that waits for confirmation never holds a stream someone else needs.
class SystemAgent {
  const SystemAgent(this.path, {this.transport});

  final String path;

  /// Replaces the socket or pipe in tests.
  final Future<Uint8List> Function(Uint8List payload)? transport;

  /// Windows OpenSSH's pipe unless `SSH_AUTH_SOCK` names another one; elsewhere `SSH_AUTH_SOCK` or nothing. A Git Bash
  /// agent's MSYS socket path is not reachable from a Windows program and is ignored.
  static SystemAgent? locate([Map<String, String>? environment]) {
    final socket = (environment ?? Platform.environment)['SSH_AUTH_SOCK'] ?? '';
    if (Platform.isWindows) {
      return SystemAgent(socket.startsWith(r'\\.\pipe\') ? socket : r'\\.\pipe\openssh-ssh-agent');
    }
    return socket.isEmpty ? null : SystemAgent(socket);
  }

  Future<Uint8List> request(Uint8List payload) {
    if (payload.isEmpty || payload.length > agentFrameLimit) throw ArgumentError('agent request size');
    if (transport case final send?) return send(payload);
    final path = this.path;
    return Platform.isWindows ? Isolate.run(() => _pipeRequest(path, payload)) : _socketRequest(path, payload);
  }

  Future<List<SSHIdentity>> identities() async => [
    for (final (blob, comment) in parseIdentities(await request(identitiesRequest())))
      _AgentIdentity(this, blob, comment),
  ];
}

Uint8List identitiesRequest() => Uint8List.fromList([AgentMessage.requestIdentities]);

/// Public key blobs and comments from an identities answer.
List<(Uint8List, String)> parseIdentities(Uint8List reply) {
  final r = _Reader(reply);
  if (r.byte() != AgentMessage.identitiesAnswer) throw const FormatException('agent refused');
  final count = r.uint32();
  if (count > 1024) throw const FormatException('agent answer');
  return [for (var i = 0; i < count; i++) (r.string(), utf8.decode(r.string(), allowMalformed: true))];
}

Uint8List signRequest(Uint8List blob, Uint8List data, int flags) {
  final w = BytesBuilder(copy: false)
    ..addByte(AgentMessage.signRequest)
    ..add(_string(blob))
    ..add(_string(data))
    ..add(_uint32(flags));
  return w.takeBytes();
}

Uint8List parseSignature(Uint8List reply) {
  final r = _Reader(reply);
  if (r.byte() != AgentMessage.signResponse) throw const FormatException('agent refused to sign');
  return r.string();
}

/// The forwarded agent only lists keys and signs; adding or removing keys, locking and extensions are refused.
class ForwardedAgent implements SSHAgentHandler {
  ForwardedAgent(this._agent);

  final SystemAgent? _agent;
  static final _failure = Uint8List.fromList([AgentMessage.failure]);

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    final agent = _agent;
    if (agent == null || request.isEmpty) return _failure;
    if (request[0] != AgentMessage.requestIdentities && request[0] != AgentMessage.signRequest) return _failure;
    try {
      return await agent.request(request);
    } on Object {
      return _failure;
    }
  }
}

class _AgentIdentity implements SSHIdentity {
  _AgentIdentity(this._agent, this._blob, this.comment) : _keyType = SSHHostKey.getType(_blob);

  final SystemAgent _agent;
  final Uint8List _blob;
  final String _keyType;
  @override
  final String comment;

  /// RSA keys sign with SHA-256, as the in-memory keys do; `ssh-rsa` (SHA-1) is never asked for.
  bool get _rsa => _keyType == 'ssh-rsa' || _keyType == 'ssh-rsa-cert-v01@openssh.com';

  @override
  String get type => switch (_keyType) {
    'ssh-rsa' => 'rsa-sha2-256',
    'ssh-rsa-cert-v01@openssh.com' => 'rsa-sha2-256-cert-v01@openssh.com',
    final other => other,
  };

  /// The agent may ask the user before signing; only keys the server accepts get that far.
  @override
  bool get shouldProbe => true;

  @override
  SSHHostKey toPublicKey() => SSHRawHostKey(_blob);

  @override
  Future<SSHSignature> sign(Uint8List data) async => SSHRawSignature(
    parseSignature(await _agent.request(signRequest(_blob, data, _rsa ? AgentMessage.rsaSha256 : 0))),
  );
}

Uint8List _uint32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value);
Uint8List _string(Uint8List bytes) =>
    (BytesBuilder(copy: false)
          ..add(_uint32(bytes.length))
          ..add(bytes))
        .takeBytes();
Uint8List _frame(Uint8List payload) => _string(payload);

class _Reader {
  _Reader(this._bytes);
  final Uint8List _bytes;
  var _at = 0;

  void _need(int n) {
    if (_at + n > _bytes.length) throw const FormatException('agent message truncated');
  }

  int byte() {
    _need(1);
    return _bytes[_at++];
  }

  int uint32() {
    _need(4);
    final value = _bytes.buffer.asByteData(_bytes.offsetInBytes).getUint32(_at);
    _at += 4;
    return value;
  }

  Uint8List string() {
    final length = uint32();
    _need(length);
    return Uint8List.sublistView(_bytes, _at, _at += length);
  }
}

/// Collects one length-prefixed reply.
class _FrameReader {
  final _buffer = BytesBuilder();

  /// The payload once [chunk] completes it.
  Uint8List? add(List<int> chunk) {
    _buffer.add(chunk);
    if (_buffer.length < 4) return null;
    final bytes = _buffer.toBytes();
    final length = bytes.buffer.asByteData().getUint32(0);
    if (length == 0 || length > agentFrameLimit) throw const FormatException('agent frame length');
    return bytes.length < 4 + length ? null : Uint8List.sublistView(bytes, 4, 4 + length);
  }
}

const _requestTimeout = Duration(seconds: 60);

Future<Uint8List> _socketRequest(String path, Uint8List payload) async {
  final socket = await Socket.connect(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
    timeout: _requestTimeout,
  );
  try {
    socket.add(_frame(payload));
    final reader = _FrameReader();
    await for (final chunk in socket.timeout(_requestTimeout)) {
      if (reader.add(chunk) case final reply?) return reply;
    }
    throw const SocketException('agent closed the connection');
  } finally {
    socket.destroy();
  }
}

/// Blocking pipe I/O; runs in its own isolate.
Uint8List _pipeRequest(String path, Uint8List payload) {
  final k = _Kernel();
  final name = path.toNativeUtf16();
  final count = calloc<Uint32>();
  final buffer = calloc<Uint8>(8192);
  var handle = _invalid;
  try {
    for (var attempt = 0; attempt < 2; attempt++) {
      handle = k.createFile(name, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, nullptr);
      if (handle != _invalid || k.getLastError() != _errorPipeBusy) break;
      k.waitNamedPipe(name, 2000);
    }
    if (handle == _invalid) throw OSError('agent pipe unavailable', k.getLastError());
    final frame = _frame(payload);
    final out = calloc<Uint8>(frame.length);
    try {
      out.asTypedList(frame.length).setAll(0, frame);
      if (k.writeFile(handle, out, frame.length, count, nullptr) == 0 || count.value != frame.length) {
        throw OSError('agent pipe write', k.getLastError());
      }
    } finally {
      calloc.free(out);
    }
    final reader = _FrameReader();
    while (true) {
      if (k.readFile(handle, buffer, 8192, count, nullptr) == 0 || count.value == 0) {
        throw OSError('agent pipe read', k.getLastError());
      }
      if (reader.add(buffer.asTypedList(count.value)) case final reply?) return Uint8List.fromList(reply);
    }
  } finally {
    if (handle != _invalid) k.closeHandle(handle);
    calloc.free(name);
    calloc.free(count);
    calloc.free(buffer);
  }
}

final _invalid = Pointer<Void>.fromAddress(-1);
const _genericRead = 0x80000000, _genericWrite = 0x40000000, _openExisting = 3, _errorPipeBusy = 231;

class _Kernel {
  final _dll = DynamicLibrary.open('kernel32.dll');
  late final createFile = _dll
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, Pointer<Void>),
        Pointer<Void> Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, Pointer<Void>)
      >('CreateFileW');
  late final waitNamedPipe = _dll
      .lookupFunction<Int32 Function(Pointer<Utf16>, Uint32), int Function(Pointer<Utf16>, int)>('WaitNamedPipeW');
  late final readFile = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('ReadFile');
  late final writeFile = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('WriteFile');
  late final closeHandle = _dll.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'CloseHandle',
  );
  late final getLastError = _dll.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}
