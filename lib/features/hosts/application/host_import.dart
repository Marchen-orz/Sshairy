import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import '../../credentials/api.dart';
import '../adapters/finalshell_login.dart';
import '../adapters/host_import_files.dart';
import '../domain/host.dart';
import '../domain/host_import.dart';
import '../domain/import_plan.dart';
import '../domain/ssh_config.dart';
import 'hosts.dart';

export '../adapters/finalshell_login.dart' show ImportSourceChanged;
export '../domain/host_import.dart' show ImportFormat;

final hostImportProvider = Provider<HostImport>(
  (ref) => HostImport(
    ref.read(hostsProvider.notifier),
    () => ref.read(hostsProvider),
    passwords: ref.read(hostPasswordImportProvider),
  ),
);

class ImportPreview {
  const ImportPreview(
    this.name,
    this.format,
    this.config,
    this.plan,
    this.revision,
    this.group, {
    String? path,
    this.passwords = const {},
  }) : path = path ?? name;

  final String name, path;
  final ImportFormat format;
  final SshConfig config;
  final SshImportPlan plan;
  final int revision;
  final String group;
  // Status only: no source text or secret in preview or UI state.
  final Set<String> passwords;

  bool canSelect(SshImportDraft draft, {bool login = true}) =>
      draft.selectable ||
      (login &&
          passwords.contains(draft.key) &&
          draft.issues.isEmpty &&
          draft.existing != null &&
          draft.existing!.proxy == null &&
          draft.existing!.policy.usesPassword &&
          !draft.existing!.policy.usesKey);

  int count(Set<String> selected, {bool login = true}) => {
    ...plan.additions(selected).map((h) => h.id),
    for (final d in plan.drafts)
      if (d.existing != null && selected.contains(d.key) && canSelect(d, login: login)) d.existing!.id,
  }.length;
}

/// Reading and planning never touch the vault. Source secrets exist only during local inspection or commit.
class HostImport {
  HostImport(this._hosts, this._saved, {this._files = const HostImportFiles(), this._passwords});

  final HostsNotifier _hosts;
  final List<Host> Function() _saved;
  final HostImportFiles _files;
  final HostPasswordImport? _passwords;
  static const _logins = FinalShellLogin();

  List<ImportFormat> get sources => [
    for (final f in ImportFormat.values)
      if (f != ImportFormat.putty || _files.hasRegistry) f,
  ];

  List<String> locations(ImportFormat format) => _files.defaults(format);

  /// Automatic discovery never decodes passwords.
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

  /// No picker fallback: the dialog shows source-specific guidance first when discovery has no result.
  Future<ImportPreview?> fromSoftware(ImportFormat format) async {
    final read = await _files.readDefault(format);
    return read == null ? null : _prepare(read);
  }

  Future<ImportPreview?> choose(ImportFormat format) async {
    final read = await _files.pick(format);
    return read == null ? null : _prepare(read);
  }

  Future<ImportPreview?> fromFile() async {
    final read = await _files.pick();
    return read == null ? null : _prepare(read);
  }

  Future<ImportPreview> _prepare(ImportRead read) async {
    final passwords = read.format == ImportFormat.finalshell
        ? (await _logins.load(read.path, read.config.hosts)).keys.toSet()
        : <String>{};
    return preview(read, passwords: passwords);
  }

  ImportPreview preview(ImportRead read, {String group = '', Set<String> passwords = const {}}) => ImportPreview(
    read.name,
    read.format,
    read.config,
    planSshConfig(read.config, _saved(), newId: HostsNotifier.newId, group: group),
    _hosts.revision,
    group,
    path: read.path,
    passwords: passwords,
  );

  ImportPreview regroup(ImportPreview p, String group) => preview(
    ImportRead(p.name, p.format, p.config, path: p.path),
    group: group,
    passwords: p.passwords,
  );

  Future<int> commit(ImportPreview preview, Set<String> selected, {bool login = true}) async {
    final chosen = {
      for (final d in preview.plan.drafts)
        if (selected.contains(d.key) && preview.canSelect(d, login: login)) d.key,
    };
    final additions = preview.plan.additions(chosen);
    final affected = preview.count(chosen, login: login);
    if (affected == 0) return 0;
    final targets = {
      for (final d in preview.plan.drafts)
        if (chosen.contains(d.key) && preview.passwords.contains(d.key)) d.key: (d.host ?? d.existing)!,
    };
    // Host edits/removal stay queued until both the secure-store operation and revision-checked write finish.
    await _hosts.importDrafts(
      additions,
      expectedRevision: preview.revision,
      aroundCommit: (persist) async {
        if (!login || _passwords == null || targets.isEmpty) {
          await persist();
          return;
        }
        final values = await _logins.load(preview.path, [
          for (final d in preview.plan.drafts)
            if (targets.containsKey(d.key)) d.source,
        ], strict: true);
        if (!values.keys.toSet().containsAll(targets.keys)) throw const ImportSourceChanged();
        final passwords = <HostId, Secret>{};
        for (final e in values.entries) {
          final target = targets[e.key]!;
          if (target.proxy != null || !target.policy.usesPassword || target.policy.usesKey) continue;
          if (passwords[target.id] case final previous?) {
            if (previous.reveal() != e.value.reveal()) throw const ImportSourceChanged();
          }
          passwords[target.id] = e.value;
        }
        try {
          await _passwords.importMissing(passwords, persist);
        } finally {
          passwords.clear();
          values.clear();
        }
      },
    );
    return affected;
  }
}
