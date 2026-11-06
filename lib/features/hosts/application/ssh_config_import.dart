import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../adapters/ssh_config_files.dart';
import '../domain/host.dart';
import '../domain/import_plan.dart';
import '../domain/ssh_config.dart';
import 'hosts.dart';

final sshConfigImportProvider = Provider<SshConfigImport>((ref) => SshConfigImport(
  ref.read(hostsProvider.notifier),
  () => ref.read(hostsProvider),
));

class SshConfigPreview {
  const SshConfigPreview(this.name, this.plan, this.revision);

  final String name;
  final SshImportPlan plan;
  final int revision;
}

/// File selection and parsing do not mutate the vault. Only [commit] adds metadata, in one revision-checked write.
class SshConfigImport {
  SshConfigImport(this._hosts, this._saved, {Future<SshConfigFile?> Function()? pickFile}) : _pickFile = pickFile ?? pickSshConfig;

  final HostsNotifier _hosts;
  final List<Host> Function() _saved;
  final Future<SshConfigFile?> Function() _pickFile;

  Future<SshConfigPreview?> pick() async {
    final file = await _pickFile();
    return file == null ? null : preview(file.input, name: file.name, username: file.username, home: file.home);
  }

  SshConfigPreview preview(SshConfigInput input, {required String name, required String username, required String home}) {
    final config = parseSshConfig(input, defaultUser: username, home: home);
    return SshConfigPreview(name, planSshConfig(config, _saved(), newId: HostsNotifier.newId), _hosts.revision);
  }

  Future<int> commit(SshConfigPreview preview, Set<String> selected) async {
    final additions = preview.plan.additions(selected);
    if (additions.isEmpty) return 0;
    await _hosts.importDrafts(additions, expectedRevision: preview.revision);
    return additions.length;
  }
}
