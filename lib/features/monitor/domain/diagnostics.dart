/// AI diagnostics have their own owner and projection; they never read monitor panel state.
enum DiagnosticTemplate { systemSummary, storageCapacity, processSummary, listeningPorts, serviceStates }

const _systemSummary =
    'sh -c \'export LC_ALL=C; '
    '[ "\$(uname -s)" = Linux ] && [ -r /proc/meminfo ] && [ -r /proc/uptime ] '
    '|| { printf "@@unsupported\\n"; exit 0; }; '
    'printf "@@system\\n"; uname -s; printf "@@kernel\\n"; uname -r; '
    'printf "@@architecture\\n"; uname -m; '
    'printf "@@load\\n"; cat /proc/loadavg; '
    'printf "@@uptime\\n"; cat /proc/uptime; '
    'printf "@@memory\\n"; cat /proc/meminfo\'';
const _storageCapacity =
    'sh -c \'export LC_ALL=C; [ "\$(uname -s)" = Linux ] '
    '|| { printf "@@unsupported\\n"; exit 0; }; '
    'printf "@@storage\\n"; df -kPTl 2>/dev/null || printf "@@failed\\n"\'';

const _processSummary = r"""sh -c 'export LC_ALL=C;
[ "$(uname -s)" = Linux ] && command -v ps >/dev/null 2>&1 && command -v awk >/dev/null 2>&1 ||
  { printf "@@unsupported\n"; exit 0; };
printf "@@processes\n";
{ ps -eo pid=,pcpu=,pmem=,rss=,comm= --sort=-pcpu 2>/dev/null || printf "@@failed\n"; } |
  awk "/^@@failed$/ { failed=1; next } NR <= 101 { print } END { if (failed) print \"@@failed\" }"'""";
const _listeningPorts = r"""sh -c 'export LC_ALL=C;
[ "$(uname -s)" = Linux ] && command -v ss >/dev/null 2>&1 && command -v awk >/dev/null 2>&1 ||
  { printf "@@unsupported\n"; exit 0; };
printf "@@listeners\n";
{ ss -H -lntu 2>/dev/null || printf "@@failed\n"; } |
  awk "/^@@failed$/ { failed=1; next } NR <= 101 { print \$1, \$2, \$5 } END { if (failed) print \"@@failed\" }"'""";
const _serviceStates = r"""sh -c 'export LC_ALL=C;
[ "$(uname -s)" = Linux ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 &&
  command -v awk >/dev/null 2>&1 || { printf "@@unsupported\n"; exit 0; };
printf "@@services\n";
{ SYSTEMD_COLORS=0 systemctl --no-pager --plain --no-legend --full --type=service --all list-units 2>/dev/null ||
  printf "@@failed\n"; } |
  awk "/^@@failed$/ { failed=1; next } NR <= 101 { print \$1, \$2, \$3, \$4 } END { if (failed) print \"@@failed\" }"'""";

/// No user-supplied shell, paths, service names or host labels are spliced into these commands.
String diagnosticCommand(DiagnosticTemplate template) => switch (template) {
  DiagnosticTemplate.systemSummary => _systemSummary,
  DiagnosticTemplate.storageCapacity => _storageCapacity,
  DiagnosticTemplate.processSummary => _processSummary,
  DiagnosticTemplate.listeningPorts => _listeningPorts,
  DiagnosticTemplate.serviceStates => _serviceStates,
};

Map<String, Object?> parseDiagnostic(DiagnosticTemplate template, String stdout) {
  if (stdout.length > 65536) return const {'supported': false, 'status': 'outputLimit'};
  final sections = <String, List<String>>{};
  List<String>? current;
  for (final raw in stdout.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.startsWith('@@')) {
      final key = line.substring(2);
      if (sections.containsKey(key)) return const {'supported': false, 'status': 'invalidOutput'};
      current = sections[key] = [];
    } else if (line.isNotEmpty && current != null) {
      current.add(line);
    }
  }
  if (sections.containsKey('unsupported')) return const {'supported': false, 'status': 'unsupported'};
  return switch (template) {
    DiagnosticTemplate.systemSummary => _parseSystem(sections),
    DiagnosticTemplate.storageCapacity => _parseStorage(sections),
    DiagnosticTemplate.processSummary => _parseRows(sections, 'processes', _processRow),
    DiagnosticTemplate.listeningPorts => _parseRows(sections, 'listeners', _listenerRow),
    DiagnosticTemplate.serviceStates => _parseRows(sections, 'services', _serviceRow),
  };
}

final _space = RegExp(r'\s+');
final _word = RegExp(r'^[A-Za-z0-9_.+\-]{1,128}$');

Map<String, Object?> _parseRows(
  Map<String, List<String>> sections,
  String section,
  Map<String, Object?>? Function(String) parseRow,
) {
  if (sections.keys.any((key) => key != section && key != 'failed') ||
      !sections.containsKey(section) ||
      (sections['failed']?.isNotEmpty ?? false)) {
    return const {'supported': false, 'status': 'invalidOutput'};
  }
  final lines = sections[section]!;
  final entries = <Map<String, Object?>>[];
  var skipped = 0;
  for (final line in lines.take(100)) {
    final entry = parseRow(line);
    if (entry == null) {
      skipped++;
    } else {
      entries.add(entry);
    }
  }
  final truncated = lines.length > 100;
  final unknownState = entries.any(
    (entry) => entry['loadState'] == 'unknown' || entry['activeState'] == 'unknown' || entry['subState'] == 'unknown',
  );
  return {
    'supported': true,
    'status': sections.containsKey('failed') || entries.isEmpty
        ? 'unknown'
        : skipped > 0 || truncated || unknownState
        ? 'partial'
        : 'ok',
    section: entries,
    'truncated': truncated,
    if (skipped > 0) 'skipped': skipped,
  };
}

final _process = RegExp(r'^\s*(\d+)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+)\s+(\S+)\s*$');
final _processName = RegExp(r'^[A-Za-z0-9_.+:/@()\[\]\-]{1,128}$');

Map<String, Object?>? _processRow(String line) {
  final match = _process.firstMatch(line);
  if (match == null || !_processName.hasMatch(match[5]!)) return null;
  final pid = int.tryParse(match[1]!);
  final cpu = _number(match[2]!);
  final memory = _number(match[3]!);
  final resident = int.tryParse(match[4]!);
  if (pid == null ||
      pid < 1 ||
      pid > 2147483647 ||
      cpu == null ||
      memory == null ||
      memory > 100 ||
      resident == null ||
      resident > _maxSafeInteger) {
    return null;
  }
  return {'pid': pid, 'name': match[5], 'cpuPercent': cpu, 'memoryPercent': memory, 'residentKib': resident};
}

Map<String, Object?>? _listenerRow(String line) {
  final fields = line.trim().split(_space);
  if (fields.length != 3 ||
      !(fields[0] == 'tcp' && fields[1] == 'LISTEN' || fields[0] == 'udp' && fields[1] == 'UNCONN')) {
    return null;
  }
  final endpoint = fields[2];
  final separator = endpoint.lastIndexOf(':');
  if (separator < 1) return null;
  var address = endpoint.substring(0, separator);
  final portText = endpoint.substring(separator + 1);
  if (!RegExp(r'^\d{1,5}$').hasMatch(portText)) return null;
  final port = int.parse(portText);
  if (port < 1 || port > 65535) return null;
  if (address.startsWith('[') && address.endsWith(']')) {
    address = address.substring(1, address.length - 1);
    if (!address.contains(':')) return null;
  }
  if (!_numericAddress(address)) return null;
  return {'protocol': fields[0], 'address': address, 'port': port};
}

bool _numericAddress(String address) {
  if (address == '*') return true;
  if (address.length > 110) return false;
  final scoped = address.split('%');
  if (scoped.length > 2 || (scoped.length == 2 && !RegExp(r'^[A-Za-z0-9_.:\-]{1,64}$').hasMatch(scoped[1]))) {
    return false;
  }
  final ip = scoped.first;
  try {
    if (ip.contains(':')) {
      Uri.parseIPv6Address(ip);
    } else {
      if (scoped.length != 1) return false;
      Uri.parseIPv4Address(ip);
    }
    return true;
  } on FormatException {
    return false;
  }
}

final _serviceName = RegExp(r'^(?:[A-Za-z0-9_:@.+\-]|\\x[0-9A-Fa-f]{2}){1,240}\.service$');
const _loadStates = {'stub', 'loaded', 'not-found', 'bad-setting', 'error', 'merged', 'masked'};
const _activeStates = {
  'active',
  'reloading',
  'inactive',
  'failed',
  'activating',
  'deactivating',
  'maintenance',
  'refreshing',
};
const _subStates = {
  'dead',
  'condition',
  'start-pre',
  'start',
  'start-post',
  'running',
  'exited',
  'reload',
  'reload-signal',
  'reload-notify',
  'stop',
  'stop-watchdog',
  'stop-sigterm',
  'stop-sigkill',
  'stop-post',
  'final-watchdog',
  'final-sigterm',
  'final-sigkill',
  'failed',
  'auto-restart',
  'auto-restart-queued',
  'cleaning',
  'dead-before-auto-restart',
  'failed-before-auto-restart',
};

Map<String, Object?>? _serviceRow(String line) {
  final fields = line.trim().split(_space);
  if (fields.length != 4 ||
      fields[0].length > 255 ||
      !_serviceName.hasMatch(fields[0]) ||
      fields.skip(1).any((field) => !_word.hasMatch(field))) {
    return null;
  }
  return {
    'name': fields[0],
    'loadState': _loadStates.contains(fields[1]) ? fields[1] : 'unknown',
    'activeState': _activeStates.contains(fields[2]) ? fields[2] : 'unknown',
    'subState': _subStates.contains(fields[3]) ? fields[3] : 'unknown',
  };
}

Map<String, Object?> _parseSystem(Map<String, List<String>> sections) {
  if (sections.keys.any(
        (key) => !const {'system', 'kernel', 'architecture', 'load', 'uptime', 'memory'}.contains(key),
      ) ||
      sections['system']?.length != 1 ||
      sections['system']?.single != 'Linux') {
    return const {'supported': false, 'status': 'invalidOutput'};
  }
  final result = <String, Object?>{'supported': true, 'system': 'Linux'};
  final missing = <String>[];
  for (final field in const ['kernel', 'architecture']) {
    final lines = sections[field];
    if (lines != null && lines.length == 1 && _word.hasMatch(lines.single)) {
      result[field] = lines.single;
    } else {
      missing.add(field);
    }
  }
  final loadLines = sections['load'];
  final load = loadLines?.length == 1 ? loadLines!.single.trim().split(_space).take(3).map(_number).toList() : null;
  if (load != null && load.length == 3 && load.every((value) => value != null)) {
    result['load'] = load;
  } else {
    missing.add('load');
  }
  final uptimeLines = sections['uptime'];
  final uptime = uptimeLines?.length == 1 ? _number(uptimeLines!.single.trim().split(_space).first) : null;
  if (uptime != null) {
    result['uptimeSeconds'] = uptime;
  } else {
    missing.add('uptimeSeconds');
  }
  const fields = {
    'MemTotal': 'totalKib',
    'MemAvailable': 'availableKib',
    'SwapTotal': 'swapTotalKib',
    'SwapFree': 'swapFreeKib',
  };
  final memory = <String, Object?>{};
  for (final line in sections['memory'] ?? const <String>[]) {
    final match = RegExp(r'^(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)\s+kB$').firstMatch(line);
    if (match == null) continue;
    final key = fields[match[1]]!;
    if (memory.containsKey(key)) return const {'supported': false, 'status': 'invalidOutput'};
    final value = int.tryParse(match[2]!);
    if (value != null && value <= _maxSafeInteger) memory[key] = value;
  }
  if (memory.isNotEmpty) result['memory'] = memory;
  if (memory.length != fields.length) missing.add('memory');
  result['status'] = missing.isEmpty ? 'ok' : 'partial';
  if (missing.isNotEmpty) result['missing'] = missing;
  return result;
}

const _maxSafeInteger = 9007199254740991;

double? _number(String value) {
  final parsed = double.tryParse(value);
  return parsed != null && parsed.isFinite && parsed >= 0 && parsed <= _maxSafeInteger ? parsed : null;
}

Map<String, Object?> _parseStorage(Map<String, List<String>> sections) {
  if (sections.keys.any((key) => !const {'storage', 'failed'}.contains(key)) || !sections.containsKey('storage')) {
    return const {'supported': false, 'status': 'invalidOutput'};
  }
  final lines = sections['storage']!;
  final entries = <Map<String, Object?>>[];
  var skipped = 0, truncated = false;
  for (final line in lines.skip(1)) {
    final match = RegExp(r'^\S+\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s+(.+)$').firstMatch(line);
    if (match == null) {
      skipped++;
      continue;
    }
    final type = match[1]!, mount = match[5]!;
    final total = int.tryParse(match[2]!), used = int.tryParse(match[3]!), available = int.tryParse(match[4]!);
    if (!_word.hasMatch(type) ||
        mount.length > 1024 ||
        !mount.startsWith('/') ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(mount) ||
        total == null ||
        used == null ||
        available == null ||
        [total, used, available].any((value) => value > _maxSafeInteger)) {
      skipped++;
      continue;
    }
    if (entries.length == 100) {
      truncated = true;
      continue;
    }
    entries.add({
      'filesystemType': type,
      'mount': mount,
      'totalKib': total,
      'usedKib': used,
      'availableKib': available,
    });
  }
  return {
    'supported': true,
    'status': sections.containsKey('failed')
        ? 'failed'
        : entries.isEmpty
        ? 'missing'
        : skipped > 0
        ? 'partial'
        : 'ok',
    'filesystems': entries,
    'truncated': truncated,
    if (skipped > 0) 'skipped': skipped,
  };
}
