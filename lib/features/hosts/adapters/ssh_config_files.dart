import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/ssh_config.dart';

class SshConfigFile {
  const SshConfigFile(this.name, this.input, this.home, this.username);

  final String name, home, username;
  final SshConfigInput input;
}

/// Expands only relative Includes inside the selected config's directory tree. No commands or key files are read.
Future<SshConfigFile> readSshConfig(String path) async {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
  final username = Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? '';
  final lines = <SshConfigLine>[];
  final issues = <SshConfigIssue>[];
  var complete = true, files = 0, bytes = 0;
  final stack = <String>{};
  late Directory root;

  String canonical(String path) => Platform.isWindows ? path.toLowerCase() : path;
  String display(String path) {
    final relative = File(path).absolute.uri.path.substring(root.absolute.uri.path.length);
    return Uri.decodeComponent(relative);
  }

  void problem(SshConfigIssueKind kind, String file, int line) {
    complete = false;
    issues.add(SshConfigIssue(kind, file, line, 'include'));
  }

  bool inside(String path) {
    final base = canonical(root.absolute.path);
    final candidate = canonical(File(path).absolute.path);
    return candidate.startsWith('$base${Platform.pathSeparator}');
  }

  Future<List<File>> expand(String pattern, String source, int line) async {
    final normalized = pattern.replaceAll(r'\', '/');
    final parts = normalized.split('/');
    if (normalized.startsWith('/') ||
        normalized.startsWith('~') ||
        normalized.contains('**') ||
        normalized.contains(r'$') ||
        normalized.contains('%') ||
        normalized.contains(':') ||
        parts.any((p) => p == '..' || p.isEmpty)) {
      problem(SshConfigIssueKind.includeOutside, source, line);
      return [];
    }
    var directories = [root];
    final found = <File>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] == '.') continue;
      final last = i == parts.length - 1;
      final next = <Directory>[];
      for (final directory in directories) {
        List<FileSystemEntity> entries;
        try {
          entries = await directory.list(followLinks: false).toList();
        } on FileSystemException {
          problem(SshConfigIssueKind.includeMissing, source, line);
          continue;
        }
        entries.sort((a, b) => a.path.compareTo(b.path));
        for (final entry in entries) {
          final name = entry.uri.pathSegments.where((p) => p.isNotEmpty).last;
          if (!sshConfigPatternMatches(parts[i], name)) continue;
          try {
            final resolved = await File(entry.path).resolveSymbolicLinks();
            if (!inside(resolved)) {
              problem(SshConfigIssueKind.includeOutside, source, line);
              continue;
            }
            final type = await FileSystemEntity.type(resolved);
            if (last && type == FileSystemEntityType.file) found.add(File(resolved));
            if (!last && type == FileSystemEntityType.directory) next.add(Directory(resolved));
          } on FileSystemException {
            problem(SshConfigIssueKind.includeMissing, source, line);
          }
          if (found.length + next.length > sshConfigMaxFiles) {
            problem(SshConfigIssueKind.includeLimit, source, line);
            return [];
          }
        }
      }
      directories = next;
    }
    return found;
  }

  Future<void> read(File file, int depth, String source, int line) async {
    if (depth > sshConfigMaxIncludeDepth || ++files > sshConfigMaxFiles) {
      problem(SshConfigIssueKind.includeLimit, source, line);
      return;
    }
    final identity = canonical(file.path);
    if (!stack.add(identity)) {
      problem(SshConfigIssueKind.includeCycle, source, line);
      return;
    }
    try {
      if (!inside(await file.resolveSymbolicLinks())) {
        problem(SshConfigIssueKind.includeOutside, source, line);
        return;
      }
      final contents = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        bytes += chunk.length;
        if (bytes > sshConfigMaxBytes) {
          problem(SshConfigIssueKind.includeLimit, source, line);
          return;
        }
        contents.add(chunk);
      }
      final text = utf8.decode(contents.takeBytes());
      final name = display(file.path);
      final raw = const LineSplitter().convert(text);
      for (var i = 0; i < raw.length; i++) {
        SshConfigDirective? directive;
        try {
          directive = sshConfigDirective(raw[i]);
        } on FormatException {
          lines.add(SshConfigLine(name, i + 1, raw[i]));
          continue;
        }
        if (directive?.keyword != 'include') {
          lines.add(SshConfigLine(name, i + 1, raw[i]));
          continue;
        }
        for (final pattern in directive!.arguments) {
          final matches = await expand(pattern, name, i + 1);
          if (matches.isEmpty) {
            problem(SshConfigIssueKind.includeMissing, name, i + 1);
          }
          for (final included in matches) {
            await read(included, depth + 1, name, i + 1);
          }
        }
      }
    } on FileSystemException {
      problem(SshConfigIssueKind.includeMissing, source, line);
    } on FormatException {
      problem(SshConfigIssueKind.malformed, source, line);
    } finally {
      stack.remove(identity);
    }
  }

  final selected = File(path);
  try {
    final actual = File(await selected.resolveSymbolicLinks());
    root = actual.parent.absolute;
    await read(actual, 0, actual.uri.pathSegments.last, 0);
  } on FileSystemException {
    complete = false;
    issues.add(const SshConfigIssue(SshConfigIssueKind.includeMissing, 'config', 0));
  }
  return SshConfigFile(
    selected.uri.pathSegments.last,
    SshConfigInput(lines, issues: issues, complete: complete),
    home,
    username,
  );
}
