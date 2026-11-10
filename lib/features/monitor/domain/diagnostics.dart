/// AI diagnostics have their own owner and projection; they never read monitor panel state.
enum DiagnosticTemplate { systemSummary, storageCapacity }

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

/// No user-supplied shell, paths, service names or host labels are spliced into these commands.
String diagnosticCommand(DiagnosticTemplate template) => switch (template) {
  DiagnosticTemplate.systemSummary => _systemSummary,
  DiagnosticTemplate.storageCapacity => _storageCapacity,
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
  };
}

final _space = RegExp(r'\s+');
final _word = RegExp(r'^[A-Za-z0-9_.+\-]{1,128}$');

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
