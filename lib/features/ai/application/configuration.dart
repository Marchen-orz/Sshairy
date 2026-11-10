import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../adapters/config_store.dart';
import '../domain/model_profile.dart';

class AiTerminalHost {
  const AiTerminalHost(this.id, this.label, this.signature);
  final HostId id;
  final String label, signature;
}

/// The app supplies effective nonsecret connection identities; editing a route invalidates its grant.
final aiTerminalHostsProvider = Provider<List<AiTerminalHost>>((_) => const []);

class AiConfiguration {
  const AiConfiguration({
    this.enabled = false,
    this.profile,
    this.revision = 0,
    this.loadFailed = false,
    this.inlineEnabled = false,
    this.completionEnabled = false,
    this.completionHistory = false,
    this.completionPosix = false,
    this.completionHosts = const {},
    this.terminalDestination,
  });

  final bool enabled, loadFailed;
  final ModelProfile? profile;
  final int revision;
  final bool inlineEnabled, completionEnabled, completionHistory, completionPosix;
  final Map<HostId, String> completionHosts;
  final String? terminalDestination;
}

final aiConfigurationProvider = NotifierProvider<AiConfigurationController, AiConfiguration>(
  AiConfigurationController.new,
);

class AiConfigurationController extends Notifier<AiConfiguration> {
  late final _store = AiConfigStore('${ref.read(dataDirProvider)}/ai.json');
  JsonFileError? _loadError;
  Future<void> _pending = Future.value(), _lastSave = Future.value();

  @override
  AiConfiguration build() => _read();

  AiConfiguration _read({bool reload = false}) {
    try {
      final value = _store.read(reload: reload);
      _loadError = null;
      return AiConfiguration(
        enabled: value.enabled,
        profile: value.profile,
        revision: value.revision,
        inlineEnabled: value.inlineEnabled,
        completionEnabled: value.completionEnabled,
        completionHistory: value.completionHistory,
        completionPosix: value.completionPosix,
        completionHosts: value.completionHosts,
        terminalDestination: value.terminalDestination,
      );
    } on JsonFileError catch (error) {
      _loadError = error;
      return const AiConfiguration(loadFailed: true);
    }
  }

  void reload() => state = _read(reload: true);

  Future<void> get saved => _lastSave.then((_) => _store.saved);

  Future<void> save({
    required bool enabled,
    required ModelProfile? profile,
    int? expectedRevision,
    bool? inlineEnabled,
    bool? completionEnabled,
    bool? completionHistory,
    bool? completionPosix,
    Map<HostId, String>? completionHosts,
  }) {
    final selectedHosts = completionHosts == null ? null : Map<HostId, String>.unmodifiable(completionHosts);
    final next = _pending.then((_) async {
      if (_loadError case final error?) throw error;
      if (enabled && profile == null) throw ArgumentError('AI profile required');
      final checked = profile == null ? null : ModelProfile.fromJson(profile.toJson());
      final changed = checked?.identity != state.profile?.identity;
      final hosts = selectedHosts ?? (changed ? <HostId, String>{} : state.completionHosts);
      final known = {for (final host in ref.read(aiTerminalHostsProvider)) host.id: host.signature};
      if (selectedHosts != null && hosts.entries.any((entry) => known[entry.key] != entry.value)) {
        throw ArgumentError('AI host selection changed');
      }
      await _store.write(
        enabled: enabled,
        profile: checked,
        expectedRevision: expectedRevision ?? state.revision,
        inlineEnabled: inlineEnabled ?? (!changed && state.inlineEnabled),
        completionEnabled: completionEnabled ?? (!changed && state.completionEnabled),
        completionHistory: completionHistory ?? (!changed && state.completionHistory),
        completionPosix: completionPosix ?? (!changed && state.completionPosix),
        completionHosts: hosts,
        terminalDestination: checked?.identity,
      );
      state = _read();
    });
    _lastSave = next;
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}
