import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/model_catalog.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/secret.dart';

void main() {
  for (final protocol in ModelProtocol.values) {
    test('${protocol.name} lists only IDs from its exact endpoint with the selected key', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = 'http://127.0.0.1:${server.port}/v1';
      final identity = jsonEncode([protocol.name, endpoint, 'default-model']);
      var calls = 0, reads = 0;
      final served = Completer<void>();
      server.listen((request) async {
        try {
          calls++;
          expect(request.method, 'GET');
          expect(request.uri.path, '/v1/models');
          expect(request.headers.value(HttpHeaders.acceptHeader), 'application/json');
          expect(await utf8.decoder.bind(request).join(), isEmpty);
          if (protocol == ModelProtocol.anthropic) {
            expect(request.headers.value('x-api-key'), 'test-key');
            expect(request.headers.value('anthropic-version'), '2023-06-01');
            expect(request.headers.value('authorization'), isNull);
          } else {
            expect(request.headers.value('authorization'), 'Bearer test-key');
            expect(request.headers.value('x-api-key'), isNull);
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'id': 'z-model', 'owned_by': 'ignored'},
                {'id': 'a-model'},
                {'id': 'a-model'},
              ],
            }),
          );
          await request.response.close();
          served.complete();
        } catch (error, stack) {
          served.completeError(error, stack);
        }
      });
      final catalog = HttpModelCatalog(
        readKey: (value) async {
          reads++;
          expect(value, identity);
          return const Secret('test-key');
        },
      );
      try {
        expect(calls, 0);
        expect(reads, 0);
        final models = await catalog.list(
          protocol: protocol,
          endpoint: endpoint,
          credentialIdentity: identity,
          cancel: CancellationToken(),
        );
        expect(models, ['a-model', 'z-model']);
        expect(() => models.add('mutation'), throwsUnsupportedError);
        await served.future;
        expect(calls, 1);
        expect(reads, 1);
      } finally {
        catalog.close();
        await server.close(force: true);
      }
    });
  }

  test('optional authentication does not read credentials and draft keys override saved keys', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = 'http://127.0.0.1:${server.port}/v1';
    final seen = <String?>[];
    server.listen((request) async {
      seen.add(request.headers.value('authorization'));
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"data":[]}');
      await request.response.close();
    });
    var reads = 0;
    final catalog = HttpModelCatalog(
      readKey: (_) async {
        reads++;
        return const Secret('saved-key');
      },
    );
    try {
      await catalog.list(protocol: ModelProtocol.openai, endpoint: endpoint, cancel: CancellationToken());
      await catalog.list(
        protocol: ModelProtocol.openai,
        endpoint: endpoint,
        credentialIdentity: jsonEncode(['openai', endpoint, 'old-model']),
        draftKey: const Secret('draft-key'),
        cancel: CancellationToken(),
      );
      expect(reads, 0);
      expect(seen, [null, 'Bearer draft-key']);
    } finally {
      catalog.close();
      await server.close(force: true);
    }
  });

  test('credential destination and invalid endpoints fail before key access or network', () async {
    var clients = 0, reads = 0;
    final catalog = HttpModelCatalog(
      readKey: (_) async {
        reads++;
        return const Secret('must-not-read');
      },
      clientFactory: () {
        clients++;
        return HttpClient();
      },
    );
    try {
      await expectLater(
        catalog.list(
          protocol: ModelProtocol.openai,
          endpoint: 'https://model.example/v1',
          credentialIdentity: jsonEncode(['openai', 'https://elsewhere.example/v1', 'model']),
          cancel: CancellationToken(),
        ),
        throwsA(isA<ModelFailure>()),
      );
      for (final endpoint in [
        'http://model.example/v1',
        'https://u:p@model.example/v1',
        'https://model.example/v1?key=x',
        'https://model.example/v1#fragment',
      ]) {
        await expectLater(
          catalog.list(protocol: ModelProtocol.openai, endpoint: endpoint, cancel: CancellationToken()),
          throwsFormatException,
        );
      }
      expect(clients, 0);
      expect(reads, 0);
    } finally {
      catalog.close();
    }
  });

  test('redirects never forward keys and error bodies are not surfaced', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((request) async {
      calls++;
      request.response.statusCode = HttpStatus.temporaryRedirect;
      request.response.headers.set(HttpHeaders.locationHeader, '/stolen');
      request.response.write('private-error-body');
      await request.response.close();
    });
    final catalog = HttpModelCatalog(readKey: (_) async => null);
    try {
      await expectLater(
        catalog.list(
          protocol: ModelProtocol.openai,
          endpoint: 'http://127.0.0.1:${server.port}/v1',
          draftKey: const Secret('test-key'),
          cancel: CancellationToken(),
        ),
        throwsA(
          isA<ModelFailure>()
              .having((error) => error.statusCode, 'status', 307)
              .having((error) => error.toString(), 'safe error', 'ModelFailure(modelCatalogHttp)'),
        ),
      );
      expect(calls, 1);
    } finally {
      catalog.close();
      await server.close(force: true);
    }
  });

  test('malformed IDs, excessive model counts, response bytes and content types are rejected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <String>[
      '{"data":[{"id":"bad\\nmodel"}]}',
      '{"data":[{"id":"${List.filled(257, 'x').join()}"}]}',
      '{"data":[{"id":12}]}',
      '{"data":{}}',
      jsonEncode({
        'data': List.generate(2001, (index) => {'id': 'm$index'}),
      }),
      List.filled(HttpModelCatalog.maxResponseBytes + 1, ' ').join(),
      '{"data":[]}',
    ];
    var index = 0;
    server.listen((request) async {
      final current = index++;
      request.response.headers.contentType = current == bodies.length - 1 ? ContentType.text : ContentType.json;
      request.response.write(bodies[current]);
      try {
        await request.response.close();
      } on Object {
        // The bounded client closes before an oversized body finishes sending.
      }
    });
    final catalog = HttpModelCatalog(readKey: (_) async => null);
    try {
      for (var i = 0; i < bodies.length; i++) {
        await expectLater(
          catalog.list(
            protocol: ModelProtocol.openai,
            endpoint: 'http://127.0.0.1:${server.port}/v1',
            cancel: CancellationToken(),
          ),
          throwsA(isA<ModelFailure>()),
        );
      }
    } finally {
      catalog.close();
      await server.close(force: true);
    }
  });

  test('Anthropic pagination stays on the same endpoint and bounds repeated pages', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cursors = <String?>[];
    var repeat = false;
    server.listen((request) async {
      final after = request.uri.queryParameters['after_id'];
      cursors.add(after);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {'id': after == null ? 'first' : 'second'},
          ],
          'has_more': after == null || repeat,
          'last_id': 'first',
        }),
      );
      await request.response.close();
    });
    final catalog = HttpModelCatalog(readKey: (_) async => null);
    try {
      expect(
        await catalog.list(
          protocol: ModelProtocol.anthropic,
          endpoint: 'http://127.0.0.1:${server.port}/v1',
          cancel: CancellationToken(),
        ),
        ['first', 'second'],
      );
      expect(cursors, [null, 'first']);
      repeat = true;
      await expectLater(
        catalog.list(
          protocol: ModelProtocol.anthropic,
          endpoint: 'http://127.0.0.1:${server.port}/v1',
          cancel: CancellationToken(),
        ),
        throwsA(isA<ModelFailure>().having((error) => error.code, 'limit', 'modelCatalogLimit')),
      );
    } finally {
      catalog.close();
      await server.close(force: true);
    }
  });

  test('cancellation or timeout during credential lookup never opens HTTP', () async {
    for (final timeout in [false, true]) {
      final pending = Completer<Secret?>();
      var clients = 0;
      final catalog = HttpModelCatalog(
        readKey: (_) => pending.future,
        timeout: timeout ? const Duration(milliseconds: 30) : const Duration(seconds: 10),
        clientFactory: () {
          clients++;
          return HttpClient();
        },
      );
      final cancel = CancellationToken();
      try {
        final work = catalog.list(
          protocol: ModelProtocol.openai,
          endpoint: 'https://model.example/v1',
          credentialIdentity: jsonEncode(['openai', 'https://model.example/v1', 'model']),
          cancel: cancel,
        );
        final check = expectLater(
          work,
          throwsA(
            isA<ModelFailure>().having((error) => error.code, 'code', timeout ? 'modelCatalogTimedOut' : 'cancelled'),
          ),
        );
        if (!timeout) cancel.cancel();
        await check;
        pending.complete(const Secret('late-key'));
        await Future<void>.delayed(Duration.zero);
        expect(clients, 0);
      } finally {
        catalog.close();
      }
    }
  });

  test('cancelAll stops active HTTP and a later explicit request can succeed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    var calls = 0;
    server.listen((request) async {
      calls++;
      if (calls == 1) {
        arrived.complete();
        return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"data":[{"id":"new-request"}]}');
      await request.response.close();
    });
    final catalog = HttpModelCatalog(readKey: (_) async => null);
    try {
      final work = catalog.list(
        protocol: ModelProtocol.openai,
        endpoint: 'http://127.0.0.1:${server.port}/v1',
        cancel: CancellationToken(),
      );
      final check = expectLater(
        work,
        throwsA(isA<ModelFailure>().having((error) => error.code, 'cancel', 'cancelled')),
      );
      await arrived.future;
      catalog.cancelAll();
      await check;
      expect(
        await catalog.list(
          protocol: ModelProtocol.openai,
          endpoint: 'http://127.0.0.1:${server.port}/v1',
          cancel: CancellationToken(),
        ),
        ['new-request'],
      );
    } finally {
      catalog.close();
      await server.close(force: true);
    }
  });
}
