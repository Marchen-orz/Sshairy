import 'dart:convert';

import 'ssh_config.dart';

/// Where hosts come from (docs/HOST_IMPORT.md). Each format other than [openssh] is turned into the same
/// [SshConfig] the SSH config parser produces, so planning, conflicts and the commit are shared.
enum ImportFormat { openssh, putty, mobaxterm, securecrt, xshell, finalshell, tabby, csv }

const importMaxFileBytes = 2 << 20;
const importMaxFiles = 4096;
const importMaxBytes = 16 << 20;
const importMaxDepth = 8;

/// A decoded file; [name] is relative to what the user chose and appears in reports.
class ImportText {
  const ImportText(this.name, this.text);

  final String name, text;
}

class _Hosts {
  _Hosts(this.defaultUser);

  final String defaultUser;
  final hosts = <SshConfigHost>[];
  final issues = <SshConfigIssue>[];
  var _next = 0;

  void report(SshConfigIssueKind kind, String file, {int line = 0, String name = ''}) =>
      issues.add(SshConfigIssue(kind, file, line, name));

  void add({
    required String name,
    required String file,
    required String? address,
    Object? port,
    String? user,
    String group = '',
    String? keyPath,
    int line = 0,
  }) {
    var host = (address ?? '').trim();
    var login = (user ?? '').trim();
    // PuTTY and others accept `user@host` in the address field.
    final at = host.lastIndexOf('@');
    if (at > 0) {
      if (login.isEmpty) login = host.substring(0, at);
      host = host.substring(at + 1);
    }
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    final number = switch (port) {
      null => 22,
      final int p => p,
      final String p when p.trim().isEmpty => 22,
      final String p => int.tryParse(p.trim()) ?? -1,
      _ => -1,
    };
    final issues = <SshConfigIssue>[
      if (host.isEmpty) SshConfigIssue(SshConfigIssueKind.noAddress, file, line),
      if (host.isNotEmpty && (number < 1 || number > 65535 || RegExp(r'[\s\x00-\x1f\x7f\[\]]').hasMatch(host)))
        SshConfigIssue(SshConfigIssueKind.invalid, file, line),
    ];
    var key = keyPath?.trim();
    if (key != null && key.toLowerCase().endsWith('.ppk')) {
      report(SshConfigIssueKind.ppk, file, line: line, name: name);
      key = null;
    }
    hosts.add(
      SshConfigHost(
        alias: name.trim().isEmpty ? host : name.trim(),
        address: host,
        username: login.isEmpty ? defaultUser : login,
        port: number < 1 ? 22 : number,
        file: file,
        line: line,
        keyPath: key == null || key.isEmpty ? null : key,
        group: group.replaceAll(r'\', '/'),
        issues: issues,
        id: '$file\u0000${_next++}',
      ),
    );
  }

  SshConfig done() {
    if (hosts.length <= sshConfigMaxHosts) return SshConfig(hosts, issues, complete: true);
    return SshConfig(hosts.sublist(0, sshConfigMaxHosts), [
      ...issues,
      SshConfigIssue(SshConfigIssueKind.hostLimit, hosts[sshConfigMaxHosts].file, 0),
    ], complete: false);
  }
}

String _stem(String name) {
  final base = name.split(RegExp(r'[/\\]')).last;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

String _folder(String name) {
  final parts = name.split(RegExp(r'[/\\]'));
  return parts.sublist(0, parts.length - 1).join('/');
}

/// Sniffs a single file by its content; null when nothing matches better than SSH config.
ImportFormat? sniffImport(String name, String text) {
  final head = text.length > 65536 ? text.substring(0, 65536) : text;
  final lower = name.toLowerCase();
  if (head.startsWith('Windows Registry Editor') || head.contains(r'\SimonTatham\PuTTY\Sessions\')) {
    return ImportFormat.putty;
  }
  if (RegExp(r'^\[Bookmarks', multiLine: true, caseSensitive: false).hasMatch(head) && head.contains('#109#')) {
    return ImportFormat.mobaxterm;
  }
  if (head.contains('S:"Hostname"=')) return ImportFormat.securecrt;
  if (RegExp(r'^\[CONNECTION\]', multiLine: true).hasMatch(head) && RegExp(r'^Host=', multiLine: true).hasMatch(head)) {
    return ImportFormat.xshell;
  }
  final trimmed = head.trimLeft();
  if (trimmed.startsWith('{') && head.contains('"host"') && head.contains('"user_name"')) {
    return ImportFormat.finalshell;
  }
  if (RegExp(r'^profiles\s*:', multiLine: true).hasMatch(head) &&
      (lower.endsWith('.yaml') || lower.endsWith('.yml') || head.contains('type: ssh'))) {
    return ImportFormat.tabby;
  }
  final first = head.split('\n').first.toLowerCase();
  if (lower.endsWith('.csv') || (first.contains(',') && _csvHeader(_csvRows(first).firstOrNull ?? []) != null)) {
    return ImportFormat.csv;
  }
  return null;
}

// PuTTY ---------------------------------------------------------------------------------------------------------

/// PuTTY's session names escape bytes as `%XX`.
String _puttyName(String raw) {
  try {
    return Uri.decodeComponent(raw);
  } on Object {
    return raw;
  }
}

/// A regedit export of `HKCU\Software\SimonTatham\PuTTY\Sessions`.
SshConfig parsePuttyReg(ImportText file, {required String defaultUser}) {
  final sessions = <String, Map<String, String>>{};
  Map<String, String>? current;
  for (final raw in const LineSplitter().convert(file.text)) {
    final line = raw.trim();
    final section = RegExp(r'^\[.*\\SimonTatham\\PuTTY\\Sessions\\(.+)\]$').firstMatch(line);
    if (section != null) {
      current = sessions.putIfAbsent(_puttyName(section[1]!), () => {});
      continue;
    }
    if (line.startsWith('[')) {
      current = null;
      continue;
    }
    final value = RegExp(r'^"([^"]+)"=(?:"((?:[^"\\]|\\.)*)"|dword:([0-9a-fA-F]{1,8}))$').firstMatch(line);
    if (current == null || value == null) continue;
    current[value[1]!] = value[3] != null
        ? '${int.parse(value[3]!, radix: 16)}'
        : value[2]!.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
  }
  return _putty(sessions, file.name, defaultUser);
}

/// The output of `reg query HKCU\Software\SimonTatham\PuTTY\Sessions /s`.
SshConfig parsePuttyQuery(String output, {required String defaultUser}) {
  final sessions = <String, Map<String, String>>{};
  Map<String, String>? current;
  for (final raw in const LineSplitter().convert(output)) {
    final key = RegExp(r'^HKEY_[A-Z_]+\\.*\\SimonTatham\\PuTTY\\Sessions\\(.+)$').firstMatch(raw.trim());
    if (key != null) {
      current = sessions.putIfAbsent(_puttyName(key[1]!), () => {});
      continue;
    }
    final value = RegExp(r'^\s+(\S+)\s+(REG_SZ|REG_EXPAND_SZ|REG_DWORD)\s*(.*)$').firstMatch(raw);
    if (current == null || value == null) continue;
    final text = value[3]!.trim();
    current[value[1]!] = value[2] == 'REG_DWORD'
        ? '${int.tryParse(text.replaceFirst(RegExp('^0x', caseSensitive: false), ''), radix: 16) ?? -1}'
        : text;
  }
  return _putty(sessions, 'PuTTY', defaultUser);
}

SshConfig _putty(Map<String, Map<String, String>> sessions, String file, String defaultUser) {
  final out = _Hosts(defaultUser);
  for (final MapEntry(key: name, value: v) in sessions.entries) {
    final address = v['HostName'] ?? '';
    if (name == 'Default Settings' && address.isEmpty) continue;
    final protocol = (v['Protocol'] ?? 'ssh').toLowerCase();
    if (protocol != 'ssh') {
      out.report(SshConfigIssueKind.notSsh, file, name: name);
      continue;
    }
    out.add(
      name: name,
      file: file,
      address: address,
      port: v['PortNumber'],
      user: v['UserName'],
      keyPath: v['PublicKeyFile'],
    );
  }
  return out.done();
}

// MobaXterm -----------------------------------------------------------------------------------------------------

/// `MobaXterm.ini` or a `.mxtsessions` export: `name=#109#flags%host%port%user%…` in `[Bookmarks*]` sections, 109
/// being SSH; `SubRep` names the folder.
SshConfig parseMobaXterm(ImportText file, {required String defaultUser}) {
  final out = _Hosts(defaultUser);
  var bookmarks = false;
  var group = '';
  for (final (i, raw) in const LineSplitter().convert(file.text).indexed) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      bookmarks = line.toLowerCase().startsWith('[bookmarks');
      group = '';
      continue;
    }
    if (!bookmarks) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final name = line.substring(0, eq).trim(), value = line.substring(eq + 1);
    if (name == 'SubRep') {
      group = value.trim();
      continue;
    }
    final type = RegExp(r'^#(\d+)#').firstMatch(value);
    if (type == null) continue;
    if (type[1] != '109') {
      out.report(SshConfigIssueKind.notSsh, file.name, line: i + 1, name: name);
      continue;
    }
    final fields = value.split('#')[2].split('%');
    String field(int n) => n < fields.length ? fields[n] : '';
    out.add(name: name, file: file.name, line: i + 1, address: field(1), port: field(2), user: field(3), group: group);
  }
  return out.done();
}

// SecureCRT -----------------------------------------------------------------------------------------------------

/// The `.ini` files of SecureCRT's `Sessions` folder; the subfolder is the group.
SshConfig parseSecureCrt(List<ImportText> files, {required String defaultUser}) {
  final out = _Hosts(defaultUser);
  for (final file in files) {
    final base = file.name.split(RegExp(r'[/\\]')).last.toLowerCase();
    if (!base.endsWith('.ini') || base == '__folderdata__.ini' || base == 'default.ini') continue;
    final values = <String, String>{};
    for (final raw in const LineSplitter().convert(file.text)) {
      final m = RegExp(r'^[SD]:"([^"]+)"=(.*)$').firstMatch(raw.trim());
      if (m != null) values[m[1]!] = m[2]!;
    }
    final protocol = values['Protocol Name'];
    if (!values.containsKey('Hostname') && protocol == null) continue;
    if (protocol != null && !protocol.toUpperCase().startsWith('SSH')) {
      out.report(SshConfigIssueKind.notSsh, file.name, name: _stem(file.name));
      continue;
    }
    final port = values['[SSH2] Port'] ?? values['Port'];
    out.add(
      name: _stem(file.name),
      file: file.name,
      address: values['Hostname'],
      port: port == null ? null : '${int.tryParse(port, radix: 16) ?? -1}',
      user: values['Username'],
      group: _folder(file.name),
    );
  }
  return out.done();
}

// Xshell --------------------------------------------------------------------------------------------------------

Map<String, Map<String, String>> _ini(String text) {
  final sections = <String, Map<String, String>>{};
  var current = sections.putIfAbsent('', () => {});
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      current = sections.putIfAbsent(line.substring(1, line.length - 1).toUpperCase(), () => {});
      continue;
    }
    final eq = line.indexOf('=');
    if (eq > 0 && !line.startsWith(';')) current[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return sections;
}

/// Xshell's `.xsh` session files; the subfolder of `Sessions` is the group.
SshConfig parseXshell(List<ImportText> files, {required String defaultUser}) {
  final out = _Hosts(defaultUser);
  for (final file in files) {
    if (!file.name.toLowerCase().endsWith('.xsh')) continue;
    final ini = _ini(file.text);
    final connection = ini['CONNECTION'] ?? const {};
    if (connection.isEmpty) continue;
    final protocol = connection['Protocol'] ?? 'SSH';
    if (protocol.toUpperCase() != 'SSH') {
      out.report(SshConfigIssueKind.notSsh, file.name, name: _stem(file.name));
      continue;
    }
    out.add(
      name: _stem(file.name),
      file: file.name,
      address: connection['Host'],
      port: connection['Port'],
      user: ini['CONNECTION:AUTHENTICATION']?['UserName'],
      group: _folder(file.name),
    );
  }
  return out.done();
}

// FinalShell ----------------------------------------------------------------------------------------------------

/// FinalShell's `*_connect_config.json` files; anything that is not such an object is reported unreadable.
SshConfig parseFinalShell(List<ImportText> files, {required String defaultUser}) {
  final out = _Hosts(defaultUser);
  for (final file in files) {
    final json = _json(file.text);
    if (json is! Map || json['host'] is! String) {
      out.report(SshConfigIssueKind.unreadable, file.name);
      continue;
    }
    String? text(String key) => json[key] is String ? json[key] as String : null;
    out.add(
      name: text('name') ?? '',
      file: file.name,
      address: text('host'),
      port: json['port'] is int || json['port'] is String ? json['port'] : null,
      user: text('user_name'),
    );
  }
  return out.done();
}

Object? _json(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// A `file://` URI as a path; [uri] itself when it has a host or query a path cannot hold.
String _filePath(String uri) {
  try {
    return Uri.parse(uri).toFilePath(windows: RegExp(r'^file:///[A-Za-z]:').hasMatch(uri));
  } on Object {
    return uri;
  }
}

// Tabby ---------------------------------------------------------------------------------------------------------

/// Tabby's `config.yaml`, already loaded into plain maps and lists by the adapter.
SshConfig parseTabby(Object? config, String file, {required String defaultUser}) {
  final out = _Hosts(defaultUser);
  if (config is! Map) {
    out.report(SshConfigIssueKind.unreadable, file);
    return out.done();
  }
  final groups = <String, String>{
    for (final g in config['groups'] is List ? config['groups'] as List : const [])
      if (g is Map && g['id'] is String && g['name'] is String) g['id'] as String: g['name'] as String,
  };
  final profiles = config['profiles'] is List ? config['profiles'] as List : const [];
  for (final p in profiles) {
    if (p is! Map) continue;
    final type = p['type'];
    final name = p['name'] is String ? p['name'] as String : '';
    if (type == 'telnet' || type == 'serial') {
      out.report(SshConfigIssueKind.notSsh, file, name: name);
    }
    if (type != 'ssh') continue;
    final options = p['options'] is Map ? p['options'] as Map : const {};
    final keys = options['privateKeys'] is List ? options['privateKeys'] as List : const [];
    var key = keys.whereType<String>().firstOrNull;
    if (key != null && key.startsWith('file://')) key = _filePath(key);
    final group = p['group'] is String ? p['group'] as String : '';
    out.add(
      name: name,
      file: file,
      address: options['host'] is String ? options['host'] as String : null,
      port: options['port'] is int || options['port'] is String ? options['port'] : null,
      user: options['user'] is String ? options['user'] as String : null,
      keyPath: key,
      group: groups[group] ?? group,
    );
  }
  return out.done();
}

// CSV -----------------------------------------------------------------------------------------------------------

enum _Column { name, address, port, user, group, key }

const _headers = {
  _Column.name: {'name', 'label', 'alias', 'title', '名称', '名字', '标签'},
  _Column.address: {'host', 'hostname', 'address', 'ip', 'server', '主机', '地址', '主机地址', 'ip地址'},
  _Column.port: {'port', '端口'},
  _Column.user: {'user', 'username', 'login', 'user name', '用户', '用户名'},
  _Column.group: {'group', 'folder', 'path', '分组', '文件夹'},
  _Column.key: {'key', 'keyfile', 'identityfile', 'identity file', 'private key', '密钥', '私钥'},
};

Map<_Column, int>? _csvHeader(List<String> row) {
  final found = <_Column, int>{};
  for (final (i, cell) in row.indexed) {
    final name = cell.trim().toLowerCase();
    for (final MapEntry(key: column, value: names) in _headers.entries) {
      if (names.contains(name)) found.putIfAbsent(column, () => i);
    }
  }
  return found.containsKey(_Column.address) ? found : null;
}

/// RFC 4180: quoted fields may hold commas, doubled quotes and line breaks.
List<List<String>> _csvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"' && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (c == '"') {
        quoted = false;
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) rows.add([...row, cell.toString()]);
  return rows;
}

const _bom = '\uFEFF';

/// A table whose first row names the columns.
SshConfig parseCsvHosts(ImportText file, {required String defaultUser}) {
  final out = _Hosts(defaultUser);
  final text = file.text.startsWith(_bom) ? file.text.substring(1) : file.text;
  final rows = _csvRows(text);
  final header = rows.isEmpty ? null : _csvHeader(rows.first);
  if (header == null) {
    out.report(SshConfigIssueKind.unreadable, file.name, line: 1);
    return out.done();
  }
  for (final (i, row) in rows.indexed.skip(1)) {
    if (row.every((c) => c.trim().isEmpty)) continue;
    String? cell(_Column c) => header[c] != null && header[c]! < row.length ? row[header[c]!] : null;
    out.add(
      name: cell(_Column.name) ?? '',
      file: file.name,
      line: i + 1,
      address: cell(_Column.address),
      port: cell(_Column.port),
      user: cell(_Column.user),
      group: cell(_Column.group) ?? '',
      keyPath: cell(_Column.key),
    );
  }
  return out.done();
}
