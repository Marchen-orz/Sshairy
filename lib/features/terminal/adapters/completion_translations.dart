import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../foundation/cancellation.dart';
import '../../settings/api.dart' show TranslationConfig;
import '../domain/completion_translation.dart';

const _target = 'zh-CN';
const _maximumEntries = 4096;
const _maximumCacheBytes = 2 * 1024 * 1024;
const _maximumFileBytes = 3 * 1024 * 1024;
const _maximumResponseBytes = 32 * 1024;

final _cacheIo = <String, Future<void>>{};

Future<void> _queueCacheIo(String path, Future<void> Function() operation) {
  final result = (_cacheIo[path] ?? Future<void>.value()).then<void>((_) => operation());
  final tail = result.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
  _cacheIo[path] = tail;
  unawaited(
    tail.then((_) {
      if (identical(_cacheIo[path], tail)) _cacheIo.remove(path);
    }),
  );
  return result;
}

String? _normalizeTarget(String languageCode) {
  if (languageCode.length > 32) return null;
  final code = languageCode.toLowerCase().replaceAll('_', '-');
  return code == 'zh' || code.startsWith('zh-') ? _target : null;
}

bool _plain(String value, {required int characters, required int bytes}) {
  if (value.isEmpty || value.length > characters || value.trim().isEmpty) {
    return false;
  }
  for (final rune in value.runes) {
    if (rune < 0x20 ||
        (rune >= 0x7f && rune <= 0x9f) ||
        rune == 0xad ||
        rune == 0x61c ||
        rune == 0x180e ||
        (rune >= 0x200b && rune <= 0x200f) ||
        (rune >= 0x2028 && rune <= 0x202e) ||
        (rune >= 0x2060 && rune <= 0x206f) ||
        rune == 0xfeff ||
        (rune >= 0xfff9 && rune <= 0xfffb) ||
        (rune >= 0xd800 && rune <= 0xdfff)) {
      return false;
    }
  }
  final encoded = utf8.encode(value);
  return encoded.length <= bytes && utf8.decode(encoded) == value;
}

bool _validOriginal(String value) => _plain(value, characters: 500, bytes: 500);
bool _validTranslation(String value) => _plain(value, characters: 2048, bytes: 8 * 1024);

typedef _TranslationKey = (String, String);

class _CachedTranslation {
  _CachedTranslation(this.text, this.bytes);
  final String text;
  final int bytes;
}

class _Cancellation {
  void Function()? action;

  void cancel() {
    final callback = action;
    action = null;
    callback?.call();
  }
}

void _watchCancellation(CancellationToken token, _Cancellation cancellation) {
  unawaited(token.whenCancelled.then((_) => cancellation.cancel()));
}

class _Waiter {
  final result = Completer<String?>();
  final cancellation = _Cancellation();

  void finish(String? text) {
    cancellation.action = null;
    if (!result.isCompleted) result.complete(text);
  }
}

class _TranslationJob {
  _TranslationJob(this.key);
  final _TranslationKey key;
  final cancel = CancellationToken();
  final waiters = <_Waiter>[];
}

/// Receives only publicly bundled descriptions authorized by the completion adapter.
class CompletionTranslations extends ChangeNotifier {
  CompletionTranslations({
    required String cacheDirectory,
    CompletionTranslationEngine? engine,
    DateTime Function()? now,
    int maxConcurrent = 32,
    Duration interval = Duration.zero,
    Duration retryDelay = const Duration(minutes: 1),
    String cacheIdentity = 'mymemory',
  }) : _directory = Directory.fromUri(Directory(cacheDirectory).absolute.uri.normalizePath()),
       _engine = engine ?? MyMemoryCompletionTranslationEngine(),
       _now = now ?? DateTime.now,
       _maxConcurrent = maxConcurrent,
       _interval = interval,
       _retryDelay = retryDelay,
       _cacheIdentity = cacheIdentity {
    if (maxConcurrent < 1 ||
        maxConcurrent > 32 ||
        interval.isNegative ||
        retryDelay.isNegative ||
        cacheIdentity.isEmpty ||
        utf8.encode(cacheIdentity).length > 4096) {
      throw ArgumentError('Invalid translation cache options');
    }
    _cacheBytes = utf8.encode(jsonEncode(_cacheData())).length;
    _ready = _queueCacheIo(_cachePath, _load);
  }

  final Directory _directory;
  final CompletionTranslationEngine _engine;
  final DateTime Function() _now;
  final int _maxConcurrent;
  final Duration _interval, _retryDelay;
  final String _cacheIdentity;
  final _cache = <_TranslationKey, _CachedTranslation>{};
  final _jobs = <_TranslationKey, _TranslationJob>{};
  final _pending = Queue<_TranslationJob>();
  late final Future<void> _ready;
  late int _cacheBytes;
  Future<void>? _writing;
  final _active = <_TranslationJob>{};
  Timer? _requestTimer, _saveTimer;
  DateTime? _nextRequest, _blockedUntil;
  bool _disposed = false, _dirty = false;

  Future<void> get ready => _ready;

  Future<void> get saved async {
    await ready;
    await _flush();
  }

  String? lookup(String original, String languageCode) {
    final target = _normalizeTarget(languageCode);
    if (_disposed || target == null || !_validOriginal(original)) return null;
    final key = (original, target);
    final entry = _cache.remove(key);
    if (entry == null) return null;
    _cache[key] = entry;
    return entry.text;
  }

  bool isPending(String original, String languageCode) {
    final target = _normalizeTarget(languageCode);
    return !_disposed && target != null && _validOriginal(original) && _jobs.containsKey((original, target));
  }

  Future<String?> translate(String original, String languageCode, {CancellationToken? cancel}) async {
    final target = _normalizeTarget(languageCode);
    if (_disposed || cancel?.isCancelled == true || target == null || !_validOriginal(original)) {
      return null;
    }
    await ready;
    if (_disposed || cancel?.isCancelled == true) return null;
    final cached = lookup(original, target);
    if (cached != null) return cached;
    final blocked = _blockedUntil;
    if (blocked != null && _now().isBefore(blocked)) return null;

    final key = (original, target);
    var job = _jobs[key];
    final created = job == null;
    if (job == null) {
      if (_pending.length >= 32) return null;
      job = _TranslationJob(key);
      _jobs[key] = job;
      _pending.add(job);
    }
    if (job.waiters.length >= 32) return null;
    final waiter = _Waiter();
    job.waiters.add(waiter);
    final attachedJob = job;
    waiter.cancellation.action = () {
      attachedJob.waiters.remove(waiter);
      waiter.finish(null);
      if (attachedJob.waiters.isEmpty) {
        attachedJob.cancel.cancel();
        _pending.remove(attachedJob);
        _finish(attachedJob, null);
        _pump();
      }
    };
    if (cancel != null) _watchCancellation(cancel, waiter.cancellation);
    if (created) notifyListeners();
    _pump();
    return waiter.result.future;
  }

  void _pump() {
    if (_disposed || _active.length >= _maxConcurrent || _pending.isEmpty) return;
    _requestTimer?.cancel();
    _requestTimer = null;
    final now = _now();
    if (_blockedUntil case final blocked? when now.isBefore(blocked)) {
      _dropPending();
      return;
    }
    while (_active.length < _maxConcurrent && _pending.isNotEmpty) {
      if (_nextRequest case final next? when now.isBefore(next)) {
        _requestTimer = Timer(next.difference(now), _pump);
        return;
      }
      final job = _pending.removeFirst();
      _active.add(job);
      _nextRequest = now.add(_interval);
      unawaited(_run(job));
    }
  }

  Future<void> _run(_TranslationJob job) async {
    String? text;
    var quota = false;
    try {
      text = await Future.any<String?>([
        _engine.translate(job.key.$1, job.key.$2, job.cancel),
        job.cancel.whenCancelled.then<String?>((_) => null),
      ]);
    } on CompletionTranslationFailure catch (failure) {
      quota = failure.quotaExceeded;
    } catch (_) {
      // External failures never enter logs or the regenerable cache.
    }
    if (!_disposed && !job.cancel.isCancelled) {
      if (text != null && _validTranslation(text)) {
        _remember(job.key, text);
        _dirty = true;
        _scheduleSave();
        _finish(job, text);
      } else {
        final delay = quota && _retryDelay < const Duration(hours: 1) ? const Duration(hours: 1) : _retryDelay;
        final until = _now().add(delay);
        if (_blockedUntil == null || until.isAfter(_blockedUntil!)) _blockedUntil = until;
        _finish(job, null);
        _dropPending();
      }
    } else {
      _finish(job, null);
    }
    job.cancel.cancel();
    _active.remove(job);
    _pump();
  }

  void _finish(_TranslationJob job, String? text) {
    final removed = identical(_jobs[job.key], job);
    if (removed) _jobs.remove(job.key);
    for (final waiter in job.waiters) {
      waiter.finish(text);
    }
    job.waiters.clear();
    if (removed && !_disposed) notifyListeners();
  }

  void _dropPending() {
    while (_pending.isNotEmpty) {
      final job = _pending.removeFirst();
      job.cancel.cancel();
      _finish(job, null);
    }
  }

  void _remember(_TranslationKey key, String text) {
    final previous = _cache.remove(key);
    if (previous != null) _cacheBytes -= previous.bytes;
    final bytes = utf8.encode(jsonEncode([key.$1, key.$2, text])).length + 1;
    while (_cache.isNotEmpty && (_cache.length >= _maximumEntries || _cacheBytes + bytes > _maximumCacheBytes)) {
      final first = _cache.keys.first;
      _cacheBytes -= _cache.remove(first)!.bytes;
    }
    _cache[key] = _CachedTranslation(text, bytes);
    _cacheBytes += bytes;
  }

  Map<String, Object> _cacheData() => {
    'version': 1,
    'identity': _cacheIdentity,
    'entries': [
      for (final entry in _cache.entries) [entry.key.$1, entry.key.$2, entry.value.text],
    ],
  };

  File get _file => File('${_directory.path}${Platform.pathSeparator}completion-translations.json');
  late final String _cachePath = Platform.isWindows ? _file.path.toLowerCase() : _file.path;

  Future<void> _load() async {
    try {
      if (!await _safeDirectory(_directory)) return;
      if (await FileSystemEntity.type(_file.path, followLinks: false) != FileSystemEntityType.file) {
        return;
      }
      if (await _file.length() > _maximumFileBytes) return;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in _file.openRead()) {
        if (bytes.length + chunk.length > _maximumFileBytes) return;
        bytes.add(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (_disposed || data is! Map || data['version'] != 1 || data['identity'] != _cacheIdentity) {
        return;
      }
      final entries = data['entries'];
      if (entries is! List) return;
      for (final entry in entries) {
        if (entry is! List || entry.length != 3) continue;
        final original = entry[0], target = entry[1], translated = entry[2];
        if (original is String &&
            target == _target &&
            translated is String &&
            _validOriginal(original) &&
            _validTranslation(translated)) {
          _remember((original, _target), translated);
        }
      }
      if (_cache.length != entries.length) {
        _dirty = true;
        _scheduleSave();
      }
      if (_cache.isNotEmpty) notifyListeners();
    } catch (_) {
      // Missing, malformed, inaccessible and oversized caches are disposable.
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      _saveTimer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_writing case final writing?) return writing;
    if (!_dirty) return Future<void>.value();
    // Reserve the whole flush before a replacement service can enqueue its load.
    final writing = _queueCacheIo(_cachePath, () async {
      try {
        while (_dirty) {
          _dirty = false;
          await _writeCache(utf8.encode(jsonEncode(_cacheData())));
        }
      } finally {
        _writing = null;
      }
    });
    _writing = writing;
    return writing;
  }

  Future<void> _writeCache(List<int> bytes) async {
    Directory? temporary;
    try {
      if (bytes.length > _maximumCacheBytes || !await _safeDirectory(_directory, create: true)) {
        return;
      }
      if (!await _safeTarget()) return;
      temporary = await _directory.createTemp('.completion-translations-');
      if (!await _safeDirectory(temporary)) return;
      final prepared = File('${temporary.path}${Platform.pathSeparator}cache.json');
      await prepared.writeAsBytes(bytes, flush: true);
      if (!await _safeDirectory(temporary) || !await _safeTarget()) return;
      // Rename replaces a regular cache atomically; failure leaves the previous cache intact.
      await prepared.rename(_file.path);
    } catch (_) {
      // Cache persistence never blocks completion or becomes authoritative configuration.
    } finally {
      if (temporary != null) {
        try {
          if (await _safeDirectory(temporary)) {
            final prepared = File('${temporary.path}${Platform.pathSeparator}cache.json');
            if (await FileSystemEntity.type(prepared.path, followLinks: false) == FileSystemEntityType.file) {
              await prepared.delete();
            }
            await temporary.delete();
          }
        } catch (_) {
          // Only this write's isolated temporary directory is eligible for cleanup.
        }
      }
    }
  }

  Future<bool> _safeTarget() async {
    if (!await _safeDirectory(_directory)) return false;
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    return type == FileSystemEntityType.notFound || type == FileSystemEntityType.file;
  }

  Future<bool> _safeDirectory(Directory directory, {bool create = false}) async {
    var current = directory;
    for (var depth = 0; depth < 128; depth++) {
      final type = await FileSystemEntity.type(current.path, followLinks: false);
      if (type != FileSystemEntityType.directory && !(create && type == FileSystemEntityType.notFound)) {
        return false;
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        if (create) {
          await directory.create(recursive: true);
          return _safeDirectory(directory);
        }
        return true;
      }
      current = parent;
    }
    return false;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _requestTimer?.cancel();
    _saveTimer?.cancel();
    for (final job in _jobs.values.toList()) {
      job.cancel.cancel();
      _finish(job, null);
    }
    for (final job in _active) {
      job.cancel.cancel();
    }
    _active.clear();
    _pending.clear();
    _engine.dispose();
    unawaited(_flush());
    super.dispose();
  }
}

/// A fresh client per request allows cancellation even before getUrl resolves.
class MyMemoryCompletionTranslationEngine implements CompletionTranslationEngine {
  MyMemoryCompletionTranslationEngine({
    HttpClient Function()? createClient,
    this.timeout = const Duration(seconds: 5),
    this.email = '',
  }) : _createClient = createClient ?? HttpClient.new {
    if (!TranslationConfig.validMyMemoryEmail(email)) throw ArgumentError('Invalid MyMemory email');
  }

  final String email;
  final HttpClient Function() _createClient;
  final Duration timeout;
  final _active = <void Function()>{};
  bool _disposed = false;

  @override
  Future<String?> translate(String original, String target, CancellationToken cancel) {
    if (_disposed || cancel.isCancelled || target != _target || !_validOriginal(original)) {
      return Future.value(null);
    }
    final result = Completer<String?>();
    final cancelAction = _Cancellation();
    HttpClient? client;
    HttpClientRequest? request;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    var stopped = false;
    late final void Function() abort;

    void finish(String? text, [CompletionTranslationFailure? failure]) {
      if (stopped) return;
      stopped = true;
      timer?.cancel();
      cancelAction.action = null;
      _active.remove(abort);
      if (text == null) {
        try {
          request?.abort(const CompletionTranslationFailure());
        } catch (_) {}
      }
      final stream = subscription;
      if (stream != null) unawaited(stream.cancel().catchError((Object _) {}));
      try {
        client?.close(force: true);
      } catch (_) {}
      if (failure != null) {
        result.completeError(failure);
      } else {
        result.complete(text);
      }
    }

    abort = () => finish(null);
    _active.add(abort);
    cancelAction.action = abort;
    _watchCancellation(cancel, cancelAction);
    timer = Timer(timeout, () => finish(null, const CompletionTranslationFailure()));
    unawaited(() async {
      try {
        final connection = _createClient();
        client = connection;
        final uri = Uri.https('api.mymemory.translated.net', '/get', {
          'q': original,
          'langpair': 'en|zh-CN',
          'mt': '1',
          if (email.isNotEmpty) 'de': email,
        });
        final opened = await connection.getUrl(uri);
        if (stopped) {
          opened.abort(const CompletionTranslationFailure());
          return;
        }
        request = opened;
        opened.followRedirects = false;
        opened.maxRedirects = 0;
        final response = await opened.close();
        if (stopped) return;
        if (response.statusCode == 429) {
          finish(null, const CompletionTranslationFailure(quotaExceeded: true));
          return;
        }
        if (response.statusCode != 200 || response.contentLength > _maximumResponseBytes) {
          finish(null, const CompletionTranslationFailure());
          return;
        }
        final bytes = BytesBuilder(copy: false);
        subscription = response.listen(
          (chunk) {
            if (stopped) return;
            if (bytes.length + chunk.length > _maximumResponseBytes) {
              finish(null, const CompletionTranslationFailure());
              return;
            }
            bytes.add(chunk);
          },
          onError: (Object _, StackTrace stack) => finish(null, const CompletionTranslationFailure()),
          onDone: () {
            if (stopped) return;
            try {
              final data = jsonDecode(utf8.decode(bytes.takeBytes()));
              if (data is! Map) throw const CompletionTranslationFailure();
              final status = data['responseStatus'];
              if (status == 429 || status == '429' || data['quotaExceeded'] == true) {
                throw const CompletionTranslationFailure(quotaExceeded: true);
              }
              if (status != 200 && status != '200') {
                throw const CompletionTranslationFailure();
              }
              final responseData = data['responseData'];
              final text = responseData is Map ? responseData['translatedText'] : null;
              if (text is! String || !_validTranslation(text)) {
                throw const CompletionTranslationFailure();
              }
              finish(text);
            } on CompletionTranslationFailure catch (failure) {
              finish(null, failure);
            } catch (_) {
              finish(null, const CompletionTranslationFailure());
            }
          },
          cancelOnError: true,
        );
        if (stopped) {
          unawaited(subscription!.cancel().catchError((Object _) {}));
        }
      } catch (_) {
        finish(null, const CompletionTranslationFailure());
      }
    }());
    return result.future;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final abort in _active.toList()) {
      abort();
    }
  }
}
