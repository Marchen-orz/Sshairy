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

  test('extended probes collect fixed columns with bounded noninteractive commands', () {
    final process = diagnosticCommand(DiagnosticTemplate.processSummary);
    final listeners = diagnosticCommand(DiagnosticTemplate.listeningPorts);
    final services = diagnosticCommand(DiagnosticTemplate.serviceStates);
    expect(process, contains('pid=,pcpu=,pmem=,rss=,comm='));
    expect(process, contains('--sort=-pcpu'));
    expect(listeners, contains('ss -H -lntu'));
    expect(services, contains('--no-pager --plain --no-legend --full --type=service --all list-units'));
    for (final command in [process, listeners, services]) {
      expect(command, startsWith("sh -c '"));
      expect(command, contains('uname -s'));
      expect(command, contains('NR <= 101'));
      expect(command, contains('@@failed'));
      for (final forbidden in ['sudo', 'args', 'environ', 'journalctl', ' status', ' restart', ' start ', ' stop ']) {
        expect(command, isNot(contains(forbidden)));
      }
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

  test('process projection keeps only PID, comm and finite resource columns', () {
    final parsed = parseDiagnostic(
      DiagnosticTemplate.processSummary,
      '@@processes\n'
      ' 20 125.3 2.5 4096 kworker/0:1\n'
      ' 21 0.0 0.1 64 sshd\n'
      '22 1.0 1.0 64 private --token=secret-should-not-leave\n'
      '23 NaN 1.0 64 invalid\n'
      '24 1.0 100.1 64 invalid\n'
      '25 1.0 1.0 64 hidden\x1b[31m\n',
    );
    expect(parsed, {
      'supported': true,
      'status': 'partial',
      'processes': [
        {'pid': 20, 'name': 'kworker/0:1', 'cpuPercent': 125.3, 'memoryPercent': 2.5, 'residentKib': 4096},
        {'pid': 21, 'name': 'sshd', 'cpuPercent': 0.0, 'memoryPercent': 0.1, 'residentKib': 64},
      ],
      'truncated': false,
      'skipped': 4,
    });
    expect(jsonEncode(parsed), isNot(contains('secret-should-not-leave')));
  });

  test('listening projection only accepts TCP listen and UDP unconnected numeric endpoints', () {
    final parsed = parseDiagnostic(
      DiagnosticTemplate.listeningPorts,
      '@@listeners\n'
      'tcp LISTEN 127.0.0.1:22\n'
      'udp UNCONN 0.0.0.0:53\n'
      'tcp LISTEN [::]:443\n'
      'udp UNCONN [fe80::1%eth0]:5353\n'
      'tcp LISTEN [::ffff:192.0.2.1]:8080\n'
      'tcp LISTEN *:9000\n'
      'tcp ESTAB 127.0.0.1:22\n'
      'tcp LISTEN private.example:22\n'
      'tcp LISTEN 999.0.0.1:22\n'
      'tcp LISTEN [1::2::3]:22\n'
      'tcp LISTEN [::]:65536\n'
      'tcp LISTEN [::]:22 users:secret-should-not-leave\n',
    );
    expect(parsed, {
      'supported': true,
      'status': 'partial',
      'listeners': [
        {'protocol': 'tcp', 'address': '127.0.0.1', 'port': 22},
        {'protocol': 'udp', 'address': '0.0.0.0', 'port': 53},
        {'protocol': 'tcp', 'address': '::', 'port': 443},
        {'protocol': 'udp', 'address': 'fe80::1%eth0', 'port': 5353},
        {'protocol': 'tcp', 'address': '::ffff:192.0.2.1', 'port': 8080},
        {'protocol': 'tcp', 'address': '*', 'port': 9000},
      ],
      'truncated': false,
      'skipped': 6,
    });
    expect(jsonEncode(parsed), isNot(contains('secret-should-not-leave')));
  });

  test('service projection uses fixed state enums and marks new state names unknown', () {
    final parsed = parseDiagnostic(
      DiagnosticTemplate.serviceStates,
      '@@services\n'
      'sshd.service loaded active running\n'
      'disabled.service masked inactive dead\n'
      'future.service future-load future-active future-sub\n'
      r'user\x2dexample@1.service loaded active exited'
      '\n'
      'described.service loaded active running secret-should-not-leave\n'
      'private.target loaded active running\n',
    );
    expect(parsed, {
      'supported': true,
      'status': 'partial',
      'services': [
        {'name': 'sshd.service', 'loadState': 'loaded', 'activeState': 'active', 'subState': 'running'},
        {'name': 'disabled.service', 'loadState': 'masked', 'activeState': 'inactive', 'subState': 'dead'},
        {'name': 'future.service', 'loadState': 'unknown', 'activeState': 'unknown', 'subState': 'unknown'},
        {'name': r'user\x2dexample@1.service', 'loadState': 'loaded', 'activeState': 'active', 'subState': 'exited'},
      ],
      'truncated': false,
      'skipped': 2,
    });
    expect(jsonEncode(parsed), isNot(contains('future-load')));
    expect(jsonEncode(parsed), isNot(contains('secret-should-not-leave')));
  });

  test('new templates bound rows, reject unexpected sections and never call missing data healthy', () {
    const templates = {
      DiagnosticTemplate.processSummary: ('processes', '1 0.0 0.0 32 sshd'),
      DiagnosticTemplate.listeningPorts: ('listeners', 'tcp LISTEN 127.0.0.1:22'),
      DiagnosticTemplate.serviceStates: ('services', 'sshd.service loaded active running'),
    };
    for (final template in templates.entries) {
      final (section, row) = template.value;
      final output = '@@$section\n${List.filled(101, row).join('\n')}\n';
      final parsed = parseDiagnostic(template.key, output);
      expect(parsed[section], hasLength(100));
      expect(parsed['status'], 'partial');
      expect(parsed['truncated'], isTrue);
      expect(parseDiagnostic(template.key, output.replaceAll('\n', '\r\n')), parsed);
      for (final absent in ['@@$section\n', '@@$section\n@@failed\n']) {
        final unknown = parseDiagnostic(template.key, absent);
        expect(unknown['status'], 'unknown');
        expect(unknown[section], isEmpty);
      }
      expect(parseDiagnostic(template.key, '@@unsupported\n')['status'], 'unsupported');
      for (final invalid in [
        '@@$section\n$row\n@@private\nsecret-should-not-leave\n',
        '@@$section\n$row\n@@$section\n$row\n',
        '@@$section\n$row\n@@failed\nsecret-should-not-leave\n',
        List.filled(65537, 'x').join(),
      ]) {
        final rejected = parseDiagnostic(template.key, invalid);
        expect(rejected['supported'], isFalse);
        expect(jsonEncode(rejected), isNot(contains('secret-should-not-leave')));
      }
    }
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
