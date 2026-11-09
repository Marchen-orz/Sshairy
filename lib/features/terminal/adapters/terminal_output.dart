import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// One shell's output, consumed independently of the view (docs/MODULES.md §3).
class TerminalOutput {
  TerminalOutput(List<Stream<Uint8List>> streams, this._write) {
    for (final stream in streams) {
      final source = _Source();
      _sources.add(source);
      _subscriptions.add(
        stream.listen((bytes) => _add(source, bytes), onDone: () => _end(source), onError: (Object e) => _fail(e)),
      );
    }
    if (streams.isEmpty) _done.complete();
  }

  static const highWater = 1024 * 1024;
  static const lowWater = 256 * 1024;
  static const sliceBytes = 8 * 1024;
  static const turnBytes = 64 * 1024;
  static const _budget = Duration(milliseconds: 4);

  final void Function(String) _write;
  final _subscriptions = <StreamSubscription<Uint8List>>[];
  final _sources = <_Source>[];
  final _queue = Queue<_Pending>();
  final _done = Completer<void>();
  final _failed = Completer<void>();
  Timer? _timer;
  var _paused = false;
  var _cancelled = false;
  var _ended = 0;
  var _pendingBytes = 0;
  Object? _error;

  /// Completes after EOF and the last queued byte, or after cancellation/error.
  Future<void> get done => _done.future;
  Future<void> get failed => _failed.future;
  Object? get error => _error;
  int get pendingBytes => _pendingBytes;

  /// Queue-owned buffer capacity, excluding the decoder's current slice and upstream buffers.
  int get retainedBytes => _queue.fold(0, (total, chunk) => total + (chunk.bytes?.buffer.lengthInBytes ?? 0));

  void _add(_Source source, Uint8List bytes) {
    if (_cancelled || source.ended || bytes.isEmpty) return;
    // Own small buffers: a view could retain an arbitrarily large input and its consumed prefix.
    for (var offset = 0; offset < bytes.length; offset += sliceBytes) {
      final end = min(bytes.length, offset + sliceBytes);
      _queue.add(_Pending(source, Uint8List.fromList(Uint8List.sublistView(bytes, offset, end))));
    }
    _pendingBytes += bytes.length;
    if (!_paused && _pendingBytes >= highWater) {
      _paused = true;
      for (final subscription in _subscriptions) {
        subscription.pause();
      }
    }
    _schedule();
  }

  void _end(_Source source) {
    if (_cancelled || source.ended) return;
    source.ended = true;
    _queue.add(_Pending(source, null));
    _schedule();
  }

  /// A lost transport may never deliver stream EOF; preserve only the bytes already accepted here.
  void finishInput() {
    if (_cancelled || _done.isCompleted) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    for (final source in _sources) {
      _end(source);
    }
  }

  void _schedule() => _timer ??= Timer(Duration.zero, _drain);

  void _drain() {
    _timer = null;
    final elapsed = Stopwatch()..start();
    var consumed = 0;
    try {
      while (!_cancelled && _queue.isNotEmpty) {
        final next = _queue.removeFirst();
        final bytes = next.bytes;
        if (bytes == null) {
          next.source.decoder.close();
          _ended++;
        } else {
          next.source.decoder.add(bytes);
          consumed += bytes.length;
          _pendingBytes -= bytes.length;
        }
        final text = next.source.text;
        if (text.isNotEmpty) {
          final data = text.toString();
          text.clear();
          _write(data);
        }
        if (_paused && _pendingBytes <= lowWater) {
          _paused = false;
          for (final subscription in _subscriptions) {
            subscription.resume();
          }
        }
        if (consumed >= turnBytes || elapsed.elapsed >= _budget) break;
      }
    } on Object catch (e) {
      _fail(e);
      return;
    }
    if (_cancelled) return;
    if (_queue.isNotEmpty) {
      _schedule();
    } else if (_ended == _subscriptions.length && !_done.isCompleted) {
      _done.complete();
    }
  }

  void _fail(Object error) {
    _error ??= error;
    if (!_failed.isCompleted) _failed.complete();
    cancel();
  }

  /// Cancelling a session deliberately discards its unparsed output.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    _pendingBytes = 0;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    if (!_done.isCompleted) _done.complete();
  }
}

class _Source {
  var ended = false;
  final text = StringBuffer();
  late final decoder = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(StringConversionSink.fromStringSink(text));
}

class _Pending {
  _Pending(this.source, this.bytes);
  final _Source source;
  final Uint8List? bytes;
}
