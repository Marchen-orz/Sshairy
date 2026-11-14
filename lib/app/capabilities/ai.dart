import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ai/api.dart';
import '../../features/capabilities/api.dart';
import '../../foundation/result.dart';

/// Purpose-built safe projections; existing host/file/settings capabilities stay private.
List<Capability> aiCapabilities(Ref ref) {
  AgentRuntime runtime() => ref.read(agentRuntimeProvider);
  AgentRuntime? authorized(RequestContext context) =>
      context.authority is AgentRuntime && identical(context.authority, runtime()) ? runtime() : null;
  Future<Result<Object?>> call(RequestContext c, Future<Result<Object?>> Function(AgentRuntime) handler) async {
    final owner = authorized(c);
    return owner == null ? const Err(AppError('notExposed')) : handler(owner);
  }

  Map<String, Object?> schema(Map<String, Object?> properties, List<String> required) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
  const host = {'type': 'string', 'minLength': 1, 'maxLength': 128};
  return [
    FunctionCapability(
      'agent.hosts',
      Effect.query,
      (a, c) => call(c, (r) async => r.listHosts(a.raw)),
      agentExposed: true,
      inputSchema: schema({
        'offset': {'type': 'integer', 'minimum': 0},
      }, []),
    ),
    FunctionCapability(
      'agent.terminals',
      Effect.query,
      (a, c) => call(c, (r) async => r.listTerminals(a.raw)),
      agentExposed: true,
      inputSchema: schema({
        'offset': {'type': 'integer', 'minimum': 0, 'maximum': 1000},
      }, []),
    ),
    FunctionCapability(
      'agent.terminalHistory',
      Effect.query,
      (a, c) => call(c, (r) async => r.readTerminalHistory(a.raw)),
      agentExposed: true,
      inputSchema: schema({'sessionId': host}, []),
    ),
    FunctionCapability(
      'agent.terminalScreen',
      Effect.query,
      (a, c) => call(c, (r) async => r.readTerminalScreen(a.raw)),
      agentExposed: true,
      inputSchema: schema({
        'sessionId': host,
        'maxLines': {'type': 'integer', 'minimum': 1, 'maximum': 200},
      }, []),
    ),
    FunctionCapability(
      'agent.diagnose',
      Effect.connect,
      (a, c) => call(c, (r) => r.diagnose(a.raw, c)),
      agentExposed: true,
      inputSchema: schema(
        {
          'hostId': host,
          'template': {
            'type': 'string',
            'enum': ['systemSummary', 'storageCapacity', 'processSummary', 'listeningPorts', 'serviceStates'],
          },
        },
        ['hostId', 'template'],
      ),
    ),
    FunctionCapability(
      'agent.execute',
      Effect.remoteWrite,
      (a, c) => call(c, (r) => r.execute(a.raw, c)),
      agentExposed: true,
      inputSchema: schema(
        {
          'hostId': host,
          'cwd': {'type': 'string', 'minLength': 1, 'maxLength': 2048},
          'command': {'type': 'string', 'minLength': 1, 'maxLength': 2048},
          'purpose': {'type': 'string', 'minLength': 1, 'maxLength': 160},
          'timeoutSeconds': {'type': 'integer', 'minimum': 1, 'maximum': 300},
        },
        ['hostId', 'cwd', 'command'],
      ),
    ),
    FunctionCapability(
      'agent.output',
      Effect.query,
      (a, c) => call(c, (r) async => r.readOutput(a.raw)),
      agentExposed: true,
      inputSchema: schema(
        {
          'hostId': host,
          'handle': {'type': 'string', 'minLength': 1, 'maxLength': 128},
        },
        ['hostId', 'handle'],
      ),
    ),
    FunctionCapability(
      'agent.jobs.start',
      Effect.remoteWrite,
      (a, c) => call(c, (r) => r.startJob(a.raw, c)),
      agentExposed: true,
      inputSchema: schema(
        {
          'hostId': host,
          'cwd': {'type': 'string', 'minLength': 1, 'maxLength': 2048},
          'command': {'type': 'string', 'minLength': 1, 'maxLength': 2048},
          'purpose': {'type': 'string', 'minLength': 1, 'maxLength': 160},
          'timeoutSeconds': {'type': 'integer', 'minimum': 1, 'maximum': 300},
        },
        ['hostId', 'cwd', 'command'],
      ),
    ),
    FunctionCapability(
      'agent.jobs.read',
      Effect.query,
      (a, c) => call(c, (r) async => r.readJob(a.raw)),
      agentExposed: true,
      inputSchema: schema(
        {
          'jobId': host,
          'offset': {'type': 'integer', 'minimum': 0},
        },
        ['jobId'],
      ),
    ),
    FunctionCapability(
      'agent.jobs.status',
      Effect.query,
      (a, c) => call(c, (r) async => r.jobStatus(a.raw)),
      agentExposed: true,
      inputSchema: schema({'jobId': host}, ['jobId']),
    ),
    FunctionCapability(
      'agent.jobs.stop',
      Effect.localChange,
      (a, c) => call(c, (r) async => r.stopJob(a.raw)),
      agentExposed: true,
      inputSchema: schema({'jobId': host}, ['jobId']),
    ),
  ];
}
