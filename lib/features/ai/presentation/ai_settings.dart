import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import '../../../l10n/app_localizations.dart';
import '../../credentials/api.dart';
import '../application/configuration.dart';
import '../domain/model_profile.dart';

class AiSettings extends ConsumerStatefulWidget {
  const AiSettings({super.key});

  @override
  ConsumerState<AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends ConsumerState<AiSettings> {
  final _endpoint = TextEditingController(), _model = TextEditingController(), _key = TextEditingController();
  final _contextWindow = TextEditingController(), _maxOutput = TextEditingController();
  final _form = GlobalKey<FormState>();
  late AiConfiguration _initial;
  late bool _enabled, _tools, _inlineEnabled, _completionEnabled, _completionHistory, _completionPosix;
  var _advanced = false;
  final _completionHosts = <HostId, String>{};
  late ModelProtocol _protocol;
  Timer? _checkTimer;
  var _generation = 0;
  var _working = false, _checking = false, _hasKey = false, _keyError = false, _removeKey = false, _conflict = false;
  String? _identity, _error;

  AiCredentials get _credentials => ref.read(aiCredentialsProvider);

  ModelProfile? get _profile {
    try {
      return ModelProfile(
        protocol: _protocol,
        endpoint: _endpoint.text.trim(),
        model: _model.text.trim(),
        tools: _tools,
        contextWindow: int.tryParse(_contextWindow.text) ?? 0,
        maxOutputTokens: int.tryParse(_maxOutput.text) ?? 0,
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  String? get _draftIdentity {
    try {
      return ModelProfile(protocol: _protocol, endpoint: _endpoint.text.trim(), model: _model.text.trim()).identity;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  bool get _emptyProfile => _endpoint.text.trim().isEmpty && _model.text.trim().isEmpty;
  bool get _credentialBlocked => (_checking || _keyError) && (_enabled || _key.text.isNotEmpty || _removeKey);
  bool get _dirty =>
      _enabled != _initial.enabled ||
      _inlineEnabled != _initial.inlineEnabled ||
      _completionEnabled != _initial.completionEnabled ||
      _completionHistory != _initial.completionHistory ||
      _completionPosix != _initial.completionPosix ||
      jsonEncode({for (final e in _completionHosts.entries) e.key.value: e.value}) !=
          jsonEncode({for (final e in _initial.completionHosts.entries) e.key.value: e.value}) ||
      jsonEncode(_profile?.toJson()) != jsonEncode(_initial.profile?.toJson()) ||
      _key.text.isNotEmpty ||
      _removeKey ||
      (!_emptyProfile && _profile == null);

  @override
  void initState() {
    super.initState();
    _load(ref.read(aiConfigurationProvider));
    _checkKey();
  }

  void _load(AiConfiguration config) {
    _checkTimer?.cancel();
    _generation++;
    _initial = config;
    _enabled = config.enabled;
    _inlineEnabled = config.inlineEnabled;
    _completionEnabled = config.completionEnabled;
    _completionHistory = config.completionHistory;
    _completionPosix = config.completionPosix;
    _completionHosts
      ..clear()
      ..addAll(config.completionHosts);
    _protocol = config.profile?.protocol ?? ModelProtocol.anthropic;
    _tools = config.profile?.tools ?? false;
    _endpoint.text = config.profile?.endpoint ?? '';
    _model.text = config.profile?.model ?? '';
    _contextWindow.text = '${config.profile?.contextWindow ?? 32768}';
    _maxOutput.text = '${config.profile?.maxOutputTokens ?? 4096}';
    _key.clear();
    _identity = _draftIdentity;
    _checking = _identity != null;
    _hasKey = _keyError = _removeKey = _conflict = false;
    _error = null;
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _generation++;
    for (final controller in [_endpoint, _model, _key, _contextWindow, _maxOutput]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed({bool identity = false}) {
    final next = _draftIdentity;
    if (identity && next != _identity) {
      _checkTimer?.cancel();
      _generation++;
      _identity = next;
      _inlineEnabled = _completionEnabled = _completionHistory = _completionPosix = false;
      _completionHosts.clear();
      _key.clear();
      _hasKey = _keyError = _removeKey = false;
      _checking = next != null;
      if (next != null) _checkTimer = Timer(const Duration(milliseconds: 250), _checkKey);
    }
    setState(() => _error = null);
  }

  Future<void> _checkKey() async {
    final identity = _identity;
    final generation = ++_generation;
    if (identity == null || _initial.loadFailed) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    setState(() {
      _checking = true;
      _keyError = false;
    });
    try {
      final exists = await _credentials.has(identity);
      if (!mounted || generation != _generation) return;
      setState(() {
        _hasKey = exists;
        _checking = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _checking = false;
        _keyError = true;
      });
    }
  }

  void _reset() {
    setState(() => _load(ref.read(aiConfigurationProvider)));
    _form.currentState?.reset();
    _checkKey();
  }

  void _configurationChanged(AiConfiguration? before, AiConfiguration next) {
    if (_working || (next.revision == _initial.revision && next.loadFailed == _initial.loadFailed)) return;
    if (_dirty) {
      setState(() => _conflict = true);
    } else {
      setState(() => _load(next));
      _checkKey();
    }
  }

  Future<void> _save() async {
    if (_working || _credentialBlocked || _conflict || _initial.loadFailed || !_form.currentState!.validate()) {
      return;
    }
    final l = AppLocalizations.of(context);
    final profile = _profile;
    if (profile == null && (_enabled || !_emptyProfile)) {
      setState(() => _error = l.aiConfigInvalid);
      return;
    }
    final enabled = _enabled, remove = _removeKey, key = _key.text, identity = profile?.identity;
    final revision = _initial.revision;
    final notifier = ref.read(aiConfigurationProvider.notifier);
    var credentialChanged = false;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (ref.read(aiConfigurationProvider).revision != revision) {
        setState(() => _conflict = true);
        return;
      }
      if (identity != null && (remove || key.isNotEmpty)) {
        if (remove) {
          await _credentials.clear(identity);
        } else {
          await _credentials.save(identity, Secret(key));
        }
        credentialChanged = true;
        if (mounted) {
          _key.clear();
          _hasKey = !remove;
          _removeKey = false;
        }
      }
      await notifier.save(
        enabled: enabled,
        profile: profile,
        expectedRevision: revision,
        inlineEnabled: _inlineEnabled,
        completionEnabled: _completionEnabled,
        completionHistory: _completionHistory,
        completionPosix: _completionPosix,
        completionHosts: _completionHosts,
      );
      if (!mounted) return;
      setState(() => _load(ref.read(aiConfigurationProvider)));
      _checkKey();
    } on Object {
      if (!mounted) return;
      setState(() {
        _error = credentialChanged ? l.aiConfigPartialSave : l.aiConfigSaveFailed;
        _conflict = ref.read(aiConfigurationProvider).revision != revision;
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(aiConfigurationProvider, _configurationChanged);
    final config = ref.watch(aiConfigurationProvider);
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final blocked = _working || config.loadFailed;
    const gap = SizedBox(height: Space.md);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (config.loadFailed) ...[
            Text(l.aiConfigLoadFailed, style: TextStyle(color: theme.colorScheme.error)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _working
                    ? null
                    : () {
                        ref.read(aiConfigurationProvider.notifier).reload();
                        _reset();
                      },
                child: Text(l.retryAction),
              ),
            ),
            gap,
          ],
          AppToggleRow(
            title: l.aiConfigEnabled,
            value: _enabled,
            onChanged: blocked ? null : (v) => setState(() => _enabled = v),
          ),
          gap,
          AppSelect<ModelProtocol>(
            value: _protocol,
            options: [
              AppOption(ModelProtocol.anthropic, l.aiConfigAnthropic),
              AppOption(ModelProtocol.openai, l.aiConfigOpenAi),
            ],
            onChanged: blocked
                ? null
                : (v) {
                    _protocol = v;
                    _changed(identity: true);
                  },
          ),
          gap,
          TextFormField(
            key: const ValueKey('ai-config-endpoint'),
            controller: _endpoint,
            enabled: !blocked,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l.aiConfigEndpoint,
              helperText: l.aiConfigEndpointHint,
              helperMaxLines: 2,
            ),
            validator: (_) => _emptyProfile && !_enabled || _profile != null ? null : l.aiConfigInvalid,
            onChanged: (_) => _changed(identity: true),
          ),
          gap,
          TextFormField(
            key: const ValueKey('ai-config-model'),
            controller: _model,
            enabled: !blocked,
            autocorrect: false,
            decoration: InputDecoration(labelText: l.aiConfigModel),
            validator: (_) => _emptyProfile && !_enabled || _profile != null ? null : l.aiConfigInvalid,
            onChanged: (_) => _changed(identity: true),
          ),
          gap,
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('ai-config-advanced'),
              onPressed: () => setState(() => _advanced = !_advanced),
              icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more, size: 16),
              label: Text(l.aiConfigAdvanced),
            ),
          ),
          if (_advanced) ...[
            AppToggleRow(
              title: l.aiConfigTools,
              value: _tools,
              onChanged: blocked ? null : (v) => setState(() => _tools = v),
            ),
            gap,
            Wrap(
              spacing: Space.md,
              runSpacing: Space.md,
              children: [
                SizedBox(
                  width: 210,
                  child: TextFormField(
                    controller: _contextWindow,
                    enabled: !blocked,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l.aiConfigContextWindow),
                    onChanged: (_) => _changed(),
                  ),
                ),
                SizedBox(
                  width: 210,
                  child: TextFormField(
                    controller: _maxOutput,
                    enabled: !blocked,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l.aiConfigMaxOutput),
                    onChanged: (_) => _changed(),
                  ),
                ),
              ],
            ),
            gap,
          ],
          TextField(
            key: const ValueKey('ai-config-key'),
            controller: _key,
            enabled: !blocked && !_checking && !_keyError && _identity != null,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: l.aiConfigApiKey),
            onChanged: (_) => setState(() {
              _removeKey = false;
              _error = null;
            }),
          ),
          const SizedBox(height: Space.xs),
          Text(
            _checking
                ? l.aiConfigKeyLoading
                : _keyError
                ? l.aiConfigKeyLoadFailed
                : _removeKey
                ? l.aiConfigKeyRemoved
                : _hasKey
                ? l.aiConfigKeySaved
                : l.aiConfigKeyMissing,
            style: theme.textTheme.bodySmall?.copyWith(color: _keyError ? theme.colorScheme.error : null),
          ),
          if (_keyError)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: blocked ? null : _checkKey, child: Text(l.retryAction)),
            ),
          if (_hasKey && !_removeKey)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: blocked
                    ? null
                    : () => setState(() {
                        _removeKey = true;
                        _key.clear();
                        _error = null;
                      }),
                child: Text(l.aiConfigRemoveKey),
              ),
            ),
          gap,
          const Divider(),
          gap,
          AppToggleRow(
            key: const ValueKey('ai-config-inline'),
            title: l.aiConfigInline,
            value: _inlineEnabled,
            onChanged: blocked || !_enabled || _profile == null ? null : (v) => setState(() => _inlineEnabled = v),
          ),
          const SizedBox(height: Space.xs),
          Text(
            l.aiConfigInlineHint,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          gap,
          AppToggleRow(
            key: const ValueKey('ai-config-completion'),
            title: l.aiConfigCompletion,
            value: _completionEnabled,
            onChanged: blocked || !_enabled || _profile == null ? null : (v) => setState(() => _completionEnabled = v),
          ),
          if (_inlineEnabled || _completionEnabled) ...[
            gap,
            Text(l.aiConfigTerminalScope, style: theme.textTheme.bodySmall),
            const SizedBox(height: Space.sm),
            for (final host in ref.watch(aiTerminalHostsProvider))
              AppToggleRow(
                key: ValueKey('ai-config-host-${host.id.value}'),
                title: host.label,
                value: _completionHosts[host.id] == host.signature,
                checkbox: true,
                onChanged: blocked
                    ? null
                    : (v) => setState(() {
                        if (v) {
                          _completionHosts[host.id] = host.signature;
                        } else {
                          _completionHosts.remove(host.id);
                        }
                      }),
              ),
            if (ref.watch(aiTerminalHostsProvider).isEmpty)
              Text(l.aiConfigTerminalNoHosts, style: theme.textTheme.bodySmall),
            const SizedBox(height: Space.sm),
            AppToggleRow(
              key: const ValueKey('ai-config-posix'),
              title: l.aiConfigPosix,
              value: _completionPosix,
              checkbox: true,
              onChanged: blocked ? null : (v) => setState(() => _completionPosix = v),
            ),
            const SizedBox(height: Space.xs),
            Text(
              l.aiConfigPosixHint,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (_completionEnabled) ...[
            gap,
            AppToggleRow(
              key: const ValueKey('ai-config-history'),
              title: l.aiConfigCompletionHistory,
              value: _completionHistory,
              onChanged: blocked ? null : (v) => setState(() => _completionHistory = v),
            ),
            const SizedBox(height: Space.xs),
            Text(
              l.aiConfigCompletionHint,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (_error != null || _conflict) ...[
            const SizedBox(height: Space.sm),
            Text(_error ?? l.aiConfigConflict, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: Space.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _working ? null : _reset, child: Text(l.cancel)),
              const SizedBox(width: Space.sm),
              FilledButton(
                key: const ValueKey('ai-config-save'),
                onPressed: blocked || _credentialBlocked || _conflict || !_dirty ? null : _save,
                child: Text(l.save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
