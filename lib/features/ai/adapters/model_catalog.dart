import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../foundation/cancellation.dart';
import '../../../foundation/secret.dart';
import '../domain/model.dart';
import '../domain/model_catalog.dart';

/// Only a user-opened picker requests this directory; no conversations or tool schemas are sent.
class HttpModelCatalog implements ModelCatalog {
  HttpModelCatalog({
    required this.readKey,
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 10),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final Future<Secret?> Function(String identity) readKey;
  final HttpClient Function() _clientFactory;
  final Duration timeout;
  final _active = <_CatalogRequest>{};
  var _closed = false;
  static const maxResponseBytes = 2 << 20, maxModels = 2000;
  static final _controls = RegExp(r'[\x00-\x20\x7f-\x9f]');

  @override
  Future<List<String>> list({
    required ModelProtocol protocol,
    required String endpoint,
    required CancellationToken cancel,
    String? credentialIdentity,
    Secret? draftKey,
  }) async {
    if (_closed || cancel.isCancelled) throw const ModelFailure('cancelled');
    final normalized = ModelProfile.normalizeEndpoint(endpoint);
    if (credentialIdentity != null) {
      Object? identity;
      try {
        identity = jsonDecode(credentialIdentity);
      } on FormatException {
        throw const ModelFailure('modelCatalogDestination');
      }
      if (identity is! List ||
          identity.length != 3 ||
          identity[0] != protocol.name ||
          identity[1] != normalized ||
          identity[2] is! String) {
        throw const ModelFailure('modelCatalogDestination');
      }
    }
    final life = _CatalogRequest(cancel, timeout);
    _active.add(life);
    try {
      final secret = draftKey ?? (credentialIdentity == null ? null : await life.wait(readKey(credentialIdentity)));
      life.check();
      final key = secret?.reveal();
      if (key != null && (key.isEmpty || key.length > 8192 || _controls.hasMatch(key))) {
        throw const ModelFailure('invalidModelKey');
      }
      final client = _clientFactory();
      life.client = client;
      client.connectionTimeout = timeout;
      final models = <String>{};
      var bytes = 0, pages = 0, count = 0;
      String? after;
      while (true) {
        life.check();
        final uri = Uri.parse(
          '$normalized/models',
        ).replace(queryParameters: protocol == ModelProtocol.anthropic ? {'limit': '1000', 'after_id': ?after} : null);
        final outgoing = await life.wait(client.getUrl(uri));
        life.check();
        outgoing.followRedirects = false;
        outgoing.maxRedirects = 0;
        outgoing.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (protocol == ModelProtocol.anthropic) {
          outgoing.headers.set('anthropic-version', '2023-06-01');
          if (key != null) outgoing.headers.set('x-api-key', key);
        } else if (key != null) {
          outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        }
        final response = await life.wait(outgoing.close());
        life.check();
        if (response.statusCode != HttpStatus.ok) {
          throw ModelFailure('modelCatalogHttp', statusCode: response.statusCode);
        }
        if (response.headers.contentType?.mimeType.toLowerCase() != 'application/json') {
          throw const ModelFailure('modelCatalogContentType');
        }
        if (response.contentLength > maxResponseBytes - bytes) throw const ModelFailure('modelCatalogLimit');
        final body = await life.wait(
          response.fold<List<int>>([], (buffer, chunk) {
            bytes += chunk.length;
            if (bytes > maxResponseBytes) throw const ModelFailure('modelCatalogLimit');
            buffer.addAll(chunk);
            return buffer;
          }),
        );
        life.check();
        final decoded = jsonDecode(utf8.decode(body));
        if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
          throw const ModelFailure('modelCatalogFormat');
        }
        final data = decoded['data'] as List;
        count += data.length;
        if (count > maxModels) throw const ModelFailure('modelCatalogLimit');
        for (final item in data) {
          if (item is! Map<String, dynamic>) throw const ModelFailure('modelCatalogFormat');
          final id = item['id'];
          if (id is! String || id.isEmpty || id.length > 256 || _controls.hasMatch(id)) {
            throw const ModelFailure('modelCatalogFormat');
          }
          models.add(id);
        }
        if (protocol != ModelProtocol.anthropic || decoded['has_more'] != true) break;
        final last = decoded['last_id'];
        if (last is! String ||
            last.isEmpty ||
            last.length > 256 ||
            _controls.hasMatch(last) ||
            last == after ||
            ++pages >= 20 ||
            models.length >= maxModels) {
          throw const ModelFailure('modelCatalogLimit');
        }
        after = last;
      }
      return List.unmodifiable(models.toList()..sort());
    } on ModelFailure {
      life.check();
      rethrow;
    } on Object {
      life.check();
      throw const ModelFailure('modelCatalogFailed');
    } finally {
      life.dispose();
      _active.remove(life);
    }
  }

  @override
  void cancelAll() {
    for (final life in _active.toList()) {
      life.abort('cancelled');
    }
  }

  @override
  void close() {
    _closed = true;
    cancelAll();
  }
}

class _CatalogCancelWatch {
  void Function()? action;
  void fire() => action?.call();
}

class _CatalogRequest {
  _CatalogRequest(CancellationToken cancel, Duration timeout) {
    final watch = _watch;
    watch.action = () => abort('cancelled');
    unawaited(cancel.whenCancelled.then((_) => watch.fire()));
    _timer = Timer(timeout, () => abort('modelCatalogTimedOut'));
    if (cancel.isCancelled) abort('cancelled');
  }

  final _watch = _CatalogCancelWatch();
  final _aborted = Completer<void>();
  late final Timer _timer;
  HttpClient? client;
  String? _failure;

  void abort(String code) {
    if (_failure != null) return;
    _failure = code;
    _timer.cancel();
    client?.close(force: true);
    _aborted.complete();
  }

  void check() {
    if (_failure case final failure?) throw ModelFailure(failure);
  }

  Future<T> wait<T>(Future<T> pending) async {
    check();
    final result = await Future.any<T>([
      pending,
      _aborted.future.then<T>((_) => throw ModelFailure(_failure ?? 'cancelled')),
    ]);
    check();
    return result;
  }

  void dispose() {
    _watch.action = null;
    _timer.cancel();
    client?.close(force: true);
  }
}
