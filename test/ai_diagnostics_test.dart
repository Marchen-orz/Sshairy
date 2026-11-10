import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/monitor/api.dart';

const _summary = '''@@system
Linux
@@kernel
6.8.0-100-generic
@@architecture
x86_64
@@load
0.25 0.50 0.75 1/10 999
@@uptime
12345.60 23456.70
@@memory
MemTotal:       16384000 kB
MemAvailable:    8192000 kB
SwapTotal:       2097152 kB
SwapFree:        1048576 kB
Buffers:          123456 kB
PrivateToken: secret-should-not-leave
''';

void main() {
  test('templates are constant noninteractive Linux probes without process or environment collection', () {
    final system = diagnosticCommand(DiagnosticTemplate.systemSummary);
    final storage = diagnosticCommand(DiagnosticTemplate.storageCapacity);
    expect(system, contains('/proc/meminfo'));
    expect(system, contains('/proc/uptime'));
    expect(storage, contains('df -kPTl'));
    for (final command in [system, storage]) {
      expect(command, startsWith("sh -c '"));
      expect(command, contains('uname -s'));
      expect(command, isNot(contains('/proc/[0-9]')));
      expect(command, isNot(contains('ps ')));
      expect(command, isNot(contains('env ')));
      expect(command, isNot(contains('sudo')));
    }
  });

  test('system projection contains only explicit finite fields, not raw text or process IDs', () {
    final parsed = parseDiagnostic(DiagnosticTemplate.systemSummary, _summary);
    expect(parsed, {
      'supported': true,
      'system': 'Linux',
      'kernel': '6.8.0-100-generic',
      'architecture': 'x86_64',
      'load': [0.25, 0.5, 0.75],
      'uptimeSeconds': 12345.6,
      'memory': {'totalKib': 16384000, 'availableKib': 8192000, 'swapTotalKib': 2097152, 'swapFreeKib': 1048576},
      'status': 'ok',
    });
    expect(jsonEncode(parsed), isNot(contains('secret-should-not-leave')));
    expect(jsonEncode(parsed), isNot(contains('999')));
    expect(parseDiagnostic(DiagnosticTemplate.systemSummary, _summary.replaceAll('\n', '\r\n')), parsed);
  });

  test('missing and invalid samples stay unknown and nonfinite values never become model evidence', () {
    final parsed = parseDiagnostic(
      DiagnosticTemplate.systemSummary,
      '@@system\nLinux\n@@load\nNaN 1 Infinity\n@@uptime\n-1\n@@memory\nMemTotal: 100 kB\n',
    );
    expect(parsed['status'], 'partial');
    expect(parsed.containsKey('load'), isFalse);
    expect(parsed.containsKey('uptimeSeconds'), isFalse);
    expect(parsed['missing'], containsAll(['kernel', 'architecture', 'load', 'uptimeSeconds', 'memory']));
    expect(parseDiagnostic(DiagnosticTemplate.systemSummary, '@@unsupported\n'), {
      'supported': false,
      'status': 'unsupported',
    });
    expect(parseDiagnostic(DiagnosticTemplate.systemSummary, '@@system\nDarwin\n')['supported'], isFalse);
    expect(parseDiagnostic(DiagnosticTemplate.systemSummary, 'unstructured private')['supported'], isFalse);
  });

  test('unknown sections, duplicate sections and oversized outputs cannot leak a raw fallback', () {
    for (final output in [
      '$_summary@@environment\nSECRET=private\n',
      '$_summary@@kernel\nsecret\n',
      List.filled(65537, 'x').join(),
    ]) {
      final parsed = parseDiagnostic(DiagnosticTemplate.systemSummary, output);
      expect(parsed['supported'], isFalse);
      expect(jsonEncode(parsed), isNot(contains('SECRET')));
      expect(parsed.containsKey('raw'), isFalse);
    }
  });

  test('storage projection omits device identities, retains allowed mounts and reports invalid rows', () {
    final parsed = parseDiagnostic(
      DiagnosticTemplate.storageCapacity,
      '@@storage\nFilesystem Type 1024-blocks Used Available Capacity Mounted on\n'
      '/dev/private-device ext4 1000 400 600 40% /\n'
      '/dev/another xfs 2000 1000 900 50% /with space\n'
      'injected secret-should-not-leave\n',
    );
    expect(parsed, {
      'supported': true,
      'status': 'partial',
      'filesystems': [
        {'filesystemType': 'ext4', 'mount': '/', 'totalKib': 1000, 'usedKib': 400, 'availableKib': 600},
        {'filesystemType': 'xfs', 'mount': '/with space', 'totalKib': 2000, 'usedKib': 1000, 'availableKib': 900},
      ],
      'truncated': false,
      'skipped': 1,
    });
    expect(jsonEncode(parsed), isNot(contains('private-device')));
    expect(jsonEncode(parsed), isNot(contains('secret-should-not-leave')));
  });

  test('storage output is bounded and collection failure never means healthy storage', () {
    final output =
        '@@storage\nFilesystem Type 1024-blocks Used Available Capacity Mounted on\n'
        '${[for (var i = 0; i < 101; i++) '/dev/d$i ext4 1000 1 999 1% /mount$i'].join('\n')}\n';
    final parsed = parseDiagnostic(DiagnosticTemplate.storageCapacity, output);
    expect(parsed['filesystems'], hasLength(100));
    expect(parsed['truncated'], isTrue);
    final failed = parseDiagnostic(DiagnosticTemplate.storageCapacity, '@@storage\n@@failed\n');
    expect(failed['status'], 'failed');
    expect(failed['filesystems'], isEmpty);
    expect(parseDiagnostic(DiagnosticTemplate.storageCapacity, 'unstructured private')['supported'], isFalse);
  });
}
