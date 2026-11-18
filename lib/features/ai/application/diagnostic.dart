import 'dart:convert';
import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../../../foundation/result.dart';
import '../../monitor/api.dart';
import '../domain/agent.dart';

export '../../monitor/api.dart' show DiagnosticTemplate;

Result<Object?> agentHostPage(List<AgentHost> hosts, int offset) {
  if (offset < 0 || offset > hosts.length) return const Err(AppError('invalidArgument', detail: 'offset'));
  final page = <Map<String, Object?>>[];
  Map<String, Object?> data() => {
    'hosts': page,
    'total': hosts.length,
    'nextOffset': offset + page.length < hosts.length ? offset + page.length : null,
  };
  for (final host in hosts.skip(offset).take(32)) {
    final label = utf8.encode(host.label);
    page.add({
      'id': host.id.value,
      'alias': label.length <= 256
          ? host.label
          : utf8.decode(label.sublist(0, 256), allowMalformed: true).replaceAll('�', ''),
    });
    if (utf8.encode(jsonEncode(data())).length > 4096) {
      page.removeLast();
      break;
    }
  }
  return Ok(data());
}

Future<int?> runAgentDiagnostic(
  AgentTarget target,
  DiagnosticTemplate template,
  void Function(bool, Uint8List) output,
  CancellationToken cancel,
) => target.execute(diagnosticCommand(template), output, timeout: const Duration(seconds: 15), cancel: cancel);

Map<String, Object?> agentDiagnosticProjection(DiagnosticTemplate template, String stdout) {
  final data = Map<String, Object?>.of(parseDiagnostic(template, stdout));
  int encodedSize() => utf8.encode(jsonEncode(jsonEncode(data))).length;
  for (final key in data.keys.toList()) {
    if (data[key] case final List entries) {
      final bounded = List<Object?>.of(entries);
      data[key] = bounded;
      while (encodedSize() > 6500 && bounded.isNotEmpty) {
        bounded.removeLast();
        data['truncated'] = true;
      }
    }
  }
  if (encodedSize() > 6500) throw const AgentFailure('outputLimit');
  return data;
}
