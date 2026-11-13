import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/result.dart';

const _schema = <String, Object?>{
  'type': 'object',
  'properties': {
    'hostId': {'type': 'string', 'minLength': 1, 'maxLength': 16, 'pattern': r'^host-[0-9]+$'},
    'options': {
      'type': 'object',
      'properties': {
        'fields': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': ['load', 'memory'],
          },
          'minItems': 1,
          'maxItems': 2,
          'uniqueItems': true,
        },
        'samples': {'type': 'integer', 'minimum': 1, 'maximum': 3},
        'ratio': {'type': 'number', 'exclusiveMinimum': 0, 'exclusiveMaximum': 1},
        'enabled': {'type': 'boolean'},
        'note': {
          'type': ['string', 'null'],
          'maxLength': 2,
        },
      },
      'required': ['fields', 'samples', 'ratio', 'enabled', 'note'],
      'additionalProperties': false,
    },
  },
  'required': ['hostId', 'options'],
  'additionalProperties': false,
};

Map<String, Object?> _valid() => {
  'hostId': 'host-1',
  'options': <String, Object?>{
    'fields': <Object?>['load'],
    'samples': 2,
    'ratio': 0.5,
    'enabled': true,
    'note': null,
  },
};

class _Authority implements AgentAuthority {
  int approvals = 0, checks = 0;
  Map<String, Object?>? approvedArgs, checkedArgs;
  RequestContext? approvedContext;
  Future<Result<void>> Function()? approval;
  Result<void> current = const Ok(null);

  @override
  Future<Result<void>> authorize(Capability capability, Map<String, Object?> args, RequestContext context) async {
    approvals++;
    approvedArgs = args;
    approvedContext = context;
    return await (approval?.call() ?? Future.value(const Ok(null)));
  }

  @override
  Future<Result<void>> revalidate(Capability capability, Map<String, Object?> args, RequestContext context) async {
    checks++;
    checkedArgs = args;
    return current;
  }
}

String? _code(Result<Object?> result) => switch (result) {
  Err(:final error) => error.code,
  _ => null,
};

void main() {
  test('request guards compose, preserve identity and fail closed', () {
    final cancel = CancellationToken();
    var routeCurrent = true, leaseCurrent = true;
    final original = RequestContext(
      Origin.agent,
      cancellation: cancel,
      deadline: DateTime.now().add(const Duration(minutes: 1)),
      authorizationIsCurrent: () => routeCurrent,
    );
    final guarded = original.withAuthorization(() => leaseCurrent);
    expect(guarded.operationId, original.operationId);
    expect(guarded.cancellation, same(cancel));
    expect(guarded.deadline, original.deadline);
    expect(guarded.isCurrent, isTrue);
    routeCurrent = false;
    expect(guarded.isCurrent, isFalse);
    routeCurrent = true;
    leaseCurrent = false;
    expect(guarded.isCurrent, isFalse);
    leaseCurrent = true;
    cancel.cancel();
    expect(guarded.isCurrent, isFalse);
    expect(RequestContext(Origin.agent, authorizationIsCurrent: () => throw StateError('stale')).isCurrent, isFalse);
    expect(
      RequestContext(Origin.agent, deadline: DateTime.now().subtract(const Duration(seconds: 1))).isCurrent,
      isFalse,
    );
  });

  group('agent authorization', () {
    late _Authority authority;
    late CapabilityDispatcher dispatcher;
    var invoked = 0;
    Map<String, Object?>? invokedArgs;
    RequestContext? invokedContext;

    setUp(() {
      authority = _Authority();
      invoked = 0;
      invokedArgs = null;
      invokedContext = null;
      dispatcher = CapabilityDispatcher([
        FunctionCapability(
          'diagnostics.collect',
          Effect.query,
          (args, context) async {
            invoked++;
            invokedArgs = args.raw;
            invokedContext = context;
            return const Ok({'state': 'collected'});
          },
          inputSchema: _schema,
          agentExposed: true,
        ),
        FunctionCapability('credentials.read', Effect.security, (_, _) async {
          invoked++;
          return const Ok(null);
        }),
      ]);
    });

    test('exposure and authority are independent gates', () async {
      expect(_code(await dispatcher.dispatch('missing', {}, RequestContext(Origin.agent))), 'unknownCapability');
      expect(
        _code(await dispatcher.dispatch('credentials.read', {}, RequestContext(Origin.agent, authority: authority))),
        'notExposed',
      );
      expect(
        _code(await dispatcher.dispatch('diagnostics.collect', _valid(), RequestContext(Origin.agent))),
        'unauthorized',
      );
      expect(authority.approvals, 0);
      expect(invoked, 0);
    });

    test('security capabilities remain nondelegable even if accidentally exposed', () async {
      final dispatcher = CapabilityDispatcher([
        FunctionCapability('security.change', Effect.security, (_, _) async {
          invoked++;
          return const Ok(null);
        }, agentExposed: true),
      ]);
      expect(
        _code(await dispatcher.dispatch('security.change', {}, RequestContext(Origin.agent, authority: authority))),
        'notExposed',
      );
      expect(authority.approvals, 0);
      expect(invoked, 0);
    });

    test('valid arguments pass both policy stages with the same operation and immutable tree', () async {
      final context = RequestContext(Origin.agent, authority: authority);
      final result = await dispatcher.dispatch('diagnostics.collect', _valid(), context);
      expect(result, isA<Ok<Object?>>());
      expect(authority.approvals, 1);
      expect(authority.checks, 1);
      expect(invoked, 1);
      expect(identical(authority.approvedArgs, authority.checkedArgs), isTrue);
      expect(identical(authority.approvedContext, invokedContext), isTrue);
      expect(invokedContext!.operationId, context.operationId);
      expect(() => invokedArgs!['hostId'] = 'host-2', throwsUnsupportedError);
      final options = invokedArgs!['options'] as Map<String, Object?>;
      expect(() => options['samples'] = 3, throwsUnsupportedError);
      expect(() => (options['fields'] as List).add('memory'), throwsUnsupportedError);
    });

    test('revoked request guard after approval blocks dispatch', () async {
      final approval = Completer<Result<void>>();
      var current = true;
      authority.approval = () => approval.future;
      final work = dispatcher.dispatch(
        'diagnostics.collect',
        _valid(),
        RequestContext(Origin.agent, authority: authority, authorizationIsCurrent: () => current),
      );
      current = false;
      approval.complete(const Ok(null));
      expect(_code(await work), 'scopeChanged');
      expect(invoked, 0);
    });

    test('caller mutations during approval cannot change approved arguments', () async {
      final approval = Completer<Result<void>>();
      authority.approval = () => approval.future;
      final args = _valid();
      final result = dispatcher.dispatch(
        'diagnostics.collect',
        args,
        RequestContext(Origin.agent, authority: authority),
      );
      expect(authority.approvals, 1);
      args['hostId'] = 'host-2';
      final options = args['options'] as Map<String, Object?>;
      options['samples'] = 3;
      (options['fields'] as List).add('memory');
      approval.complete(const Ok(null));
      expect(await result, isA<Ok<Object?>>());
      expect(invokedArgs!['hostId'], 'host-1');
      expect((invokedArgs!['options'] as Map)['samples'], 2);
      expect((invokedArgs!['options'] as Map)['fields'], ['load']);
    });

    test('denied approval never invokes or revalidates', () async {
      authority.approval = () async => const Err(AppError('approvalDenied'));
      expect(
        _code(
          await dispatcher.dispatch(
            'diagnostics.collect',
            _valid(),
            RequestContext(Origin.agent, authority: authority),
          ),
        ),
        'approvalDenied',
      );
      expect(authority.checks, 0);
      expect(invoked, 0);
    });

    test('scope or connection changes after approval reject before the handler', () async {
      authority.current = const Err(AppError('staleApproval'));
      expect(
        _code(
          await dispatcher.dispatch(
            'diagnostics.collect',
            _valid(),
            RequestContext(Origin.agent, authority: authority),
          ),
        ),
        'staleApproval',
      );
      expect(authority.approvals, 1);
      expect(authority.checks, 1);
      expect(invoked, 0);
    });

    test('invalid shape is rejected before policy without returning argument contents', () async {
      final args = _valid()..['untrusted'] = 'test-secret-in-unknown-field';
      final result = await dispatcher.dispatch(
        'diagnostics.collect',
        args,
        RequestContext(Origin.agent, authority: authority),
      );
      expect(_code(result), 'invalidArgument');
      expect((result as Err).error.detail, isEmpty);
      expect(authority.approvals, 0);
      expect(invoked, 0);
    });

    test('cancellation before dispatch skips approval and execution', () async {
      final token = CancellationToken()..cancel();
      expect(
        _code(
          await dispatcher.dispatch(
            'diagnostics.collect',
            _valid(),
            RequestContext(Origin.agent, authority: authority, cancellation: token),
          ),
        ),
        'cancelled',
      );
      expect(authority.approvals, 0);
      expect(invoked, 0);
    });

    test('cancellation releases a pending approval wait and late approval cannot execute', () async {
      final approval = Completer<Result<void>>();
      authority.approval = () => approval.future;
      final token = CancellationToken();
      final result = dispatcher.dispatch(
        'diagnostics.collect',
        _valid(),
        RequestContext(Origin.agent, authority: authority, cancellation: token),
      );
      token.cancel();
      expect(_code(await result), 'cancelled');
      approval.complete(const Ok(null));
      await pumpEventQueue();
      expect(authority.checks, 0);
      expect(invoked, 0);
    });

    test('expired deadline skips policy and execution', () async {
      expect(
        _code(
          await dispatcher.dispatch(
            'diagnostics.collect',
            _valid(),
            RequestContext(
              Origin.agent,
              authority: authority,
              deadline: DateTime.now().subtract(const Duration(seconds: 1)),
            ),
          ),
        ),
        'deadlineExceeded',
      );
      expect(authority.approvals, 0);
      expect(invoked, 0);
    });

    test('deadline bounds an approval wait and ignores late policy failures', () async {
      final approval = Completer<Result<void>>();
      authority.approval = () => approval.future;
      final result = dispatcher.dispatch(
        'diagnostics.collect',
        _valid(),
        RequestContext(
          Origin.agent,
          authority: authority,
          deadline: DateTime.now().add(const Duration(milliseconds: 20)),
        ),
      );
      expect(_code(await result), 'deadlineExceeded');
      approval.completeError(StateError('late policy error'));
      await pumpEventQueue();
      expect(invoked, 0);
    });

    test('cancellation from final target check is caught before invoking the handler', () async {
      final token = CancellationToken();
      final check = _CancellingAuthority(token);
      expect(
        _code(
          await dispatcher.dispatch(
            'diagnostics.collect',
            _valid(),
            RequestContext(Origin.agent, authority: check, cancellation: token),
          ),
        ),
        'cancelled',
      );
      expect(invoked, 0);
    });

    test('agent handler argument errors never echo model values', () async {
      final dispatcher = CapabilityDispatcher([
        FunctionCapability('test.invalid', Effect.query, (_, _) async {
          throw ArgumentError.value('test-secret', 'command', 'test-secret-message');
        }, agentExposed: true),
      ]);
      final result = await dispatcher.dispatch('test.invalid', {}, RequestContext(Origin.agent, authority: authority));
      expect(_code(result), 'invalidArgument');
      expect((result as Err).error.detail, isEmpty);
    });

    test('existing palette and UI handlers retain their own validation behavior', () async {
      for (final origin in [Origin.ui, Origin.palette]) {
        expect(
          await dispatcher.dispatch('credentials.read', {'legacyArg': Object()}, RequestContext(origin)),
          isA<Ok<Object?>>(),
        );
      }
      expect(invoked, 2);
      expect(authority.approvals, 0);
    });
  });

  group('restricted tool schemas', () {
    bool accepts(Map<String, Object?> args) => CapabilitySchema.validate(_schema, args) is Ok;

    test('required, unknown, string pattern and bounds are strict', () {
      expect(accepts(_valid()..remove('hostId')), isFalse);
      expect(accepts(_valid()..['hostId'] = 1), isFalse);
      expect(accepts(_valid()..['hostId'] = ''), isFalse);
      expect(accepts(_valid()..['hostId'] = 'host-1234567890123456'), isFalse);
      expect(accepts(_valid()..['hostId'] = 'other-1'), isFalse);
      expect(accepts(_valid()..['origin'] = 'ui'), isFalse);
      final args = _valid();
      (args['options'] as Map)['grant'] = 'all-hosts';
      expect(accepts(args), isFalse);
    });

    test('arrays validate every item, bounds, enum and structural uniqueness', () {
      for (final fields in [
        [],
        ['load', 'memory', 'load'],
        ['load', 'load'],
        ['other'],
        [1],
      ]) {
        final args = _valid();
        (args['options'] as Map)['fields'] = fields;
        expect(accepts(args), isFalse);
      }
      final args = _valid();
      (args['options'] as Map)['fields'] = ['load', 'memory'];
      expect(accepts(args), isTrue);
      const schema = <String, Object?>{
        'type': 'object',
        'properties': {
          'items': {
            'type': 'array',
            'uniqueItems': true,
            'items': {
              'type': 'object',
              'properties': {
                'a': {'type': 'number'},
                'b': {'type': 'boolean'},
              },
            },
          },
        },
      };
      expect(
        CapabilitySchema.validate(schema, {
          'items': [
            {'a': 1, 'b': true},
            {'b': true, 'a': 1.0},
          ],
        }),
        isA<Err>(),
      );
    });

    test('numeric, boolean and nullable fields have no implicit coercion', () {
      for (final field in ['samples', 'ratio', 'enabled', 'note']) {
        final args = _valid();
        (args['options'] as Map)[field] = 'true';
        expect(accepts(args), isFalse);
      }
      for (final sample in [0, 4, 1.5, double.nan, double.infinity]) {
        final args = _valid();
        (args['options'] as Map)['samples'] = sample;
        expect(accepts(args), isFalse);
      }
      for (final ratio in [0, 1, double.negativeInfinity]) {
        final args = _valid();
        (args['options'] as Map)['ratio'] = ratio;
        expect(accepts(args), isFalse);
      }
      final args = _valid();
      (args['options'] as Map)['note'] = '😀中';
      expect(accepts(args), isTrue);
      (args['options'] as Map)['note'] = '😀中文';
      expect(accepts(args), isFalse);
    });

    test('unknown or malformed schema keywords fail closed even in absent fields', () {
      for (final child in <Map<String, Object?>>[
        {'type': 'string', 'format': 'uri'},
        {'type': 'object', 'additionalProperties': true},
        {'type': 'array'},
        {'type': 'string', 'minLength': -1},
        {'type': 'string', 'minLength': 5, 'maxLength': 1},
        {'type': 'string', 'pattern': '['},
        {'type': 'string', 'enum': []},
        {
          'type': 'object',
          'required': ['unknown'],
        },
        {'type': 'object', 'required': null},
        {'type': 'object', 'properties': null},
        {'type': 'number', 'minimum': double.nan},
        {'type': 'mystery'},
        {
          'type': ['string', 'string'],
        },
        {
          'anyOf': [
            {'type': 'string'},
            {'type': 'null'},
          ],
        },
      ]) {
        final result = CapabilitySchema.validate({
          'type': 'object',
          'properties': {'unused': child},
        }, {});
        expect((result as Err).error.code, 'invalidSchema');
      }
    });

    test('argument and schema budgets reject cycles, non-JSON values, excessive depth, bytes and nodes', () {
      final cycle = <String, Object?>{};
      cycle['self'] = cycle;
      expect(CapabilitySchema.validate({'type': 'object'}, cycle), isA<Err>());
      expect(CapabilitySchema.validate({'type': 'object'}, {'v': Object()}), isA<Err>());
      expect(CapabilitySchema.validate({'type': 'object'}, {'v': List.filled(5000, null)}), isA<Err>());
      expect(CapabilitySchema.validate({'type': 'object'}, {'v': 'x' * (CapabilitySchema.maxBytes + 1)}), isA<Err>());
      Object? nested;
      for (var i = 0; i < 20; i++) {
        nested = [nested];
      }
      expect(CapabilitySchema.validate({'type': 'object'}, {'v': nested}), isA<Err>());
      final cyclicSchema = <String, Object?>{'type': 'object'};
      cyclicSchema['properties'] = {'next': cyclicSchema};
      expect((CapabilitySchema.validate(cyclicSchema, {}) as Err).error.code, 'invalidSchema');
    });
  });
}

class _CancellingAuthority implements AgentAuthority {
  _CancellingAuthority(this.token);
  final CancellationToken token;
  @override
  Future<Result<void>> authorize(Capability capability, Map<String, Object?> args, RequestContext context) async =>
      const Ok(null);
  @override
  Future<Result<void>> revalidate(Capability capability, Map<String, Object?> args, RequestContext context) async {
    token.cancel();
    return const Ok(null);
  }
}
