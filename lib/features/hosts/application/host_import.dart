import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../adapters/host_import_files.dart';
import '../domain/host.dart';
import '../domain/host_import.dart';
import '../domain/import_plan.dart';
import '../domain/ssh_config.dart';
import 'hosts.dart';

export '../domain/host_import.dart' show ImportFormat;

final hostImportProvider = Provider<HostImport>(
  (ref) => HostImport(ref.read(hostsProvider.notifier), () => ref.read(hostsProvider)),
);

class ImportPreview {
  const ImportPreview(this.name, this.format, this.config, this.plan, this.revision, this.group);

  final String name;
  final ImportFormat format;
  final SshConfig config;
  final SshImportPlan plan;
  final int revision;

  /// Where new hosts go; their source folders stay below it.
  final String group;
}

/// Reading and planning never touch the vault; only [commit] adds hosts, in one revision-checked write
/// (docs/HOST_IMPORT.md).
class HostImport {
  HostImport(this._hosts, this._saved, {this._files = const HostImportFiles()});

  final HostsNotifier _hosts;
  final List<Host> Function() _saved;
  final HostImportFiles _files;

  /// The sources offered as tiles; PuTTY only where its registry key exists.
  List<ImportFormat> get sources => [
    for (final f in ImportFormat.values)
      if (f != ImportFormat.putty || _files.hasRegistry) f,
  ];

  /// Hosts found where each program keeps them; programs that are not there are left out.
  Future<Map<ImportFormat, int>> detect() async {
    final counts = <ImportFormat, int>{};
    for (final format in ImportFormat.values) {
      try {
        final read = await _files.readDefault(format);
        if (read != null && read.config.hosts.isNotEmpty) counts[format] = read.config.hosts.length;
      } on Object {
        continue;
      }
    }
    return counts;
  }

  /// From the program's own place when it is there, otherwise from a file or folder the user picks.
  Future<ImportPreview?> fromSoftware(ImportFormat format) async {
    final read = await _files.readDefault(format) ?? await _files.pick(format);
    return read == null ? null : preview(read);
  }

  /// Any file; the format is recognised from its content.
  Future<ImportPreview?> fromFile() async {
    final read = await _files.pick();
    return read == null ? null : preview(read);
  }

  ImportPreview preview(ImportRead read, {String group = ''}) => ImportPreview(
    read.name,
    read.format,
    read.config,
    planSshConfig(read.config, _saved(), newId: HostsNotifier.newId, group: group),
    _hosts.revision,
    group,
  );

  /// The same hosts planned into another group.
  ImportPreview regroup(ImportPreview preview, String group) =>
      this.preview(ImportRead(preview.name, preview.format, preview.config), group: group);

  Future<int> commit(ImportPreview preview, Set<String> selected) async {
    final additions = preview.plan.additions(selected);
    if (additions.isEmpty) return 0;
    await _hosts.importDrafts(additions, expectedRevision: preview.revision);
    return additions.length;
  }
}
