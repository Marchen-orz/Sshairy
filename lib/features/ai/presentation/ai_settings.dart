import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/form_field.dart';
import '../../../design/form_save.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import '../../../l10n/app_localizations.dart';
import '../../credentials/api.dart';
import '../application/configuration.dart';
import '../application/model_credentials.dart';
import '../application/model_selection.dart';
import '../application/providers.dart';
import '../domain/model_profile.dart';
import 'model_picker.dart';

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
  late bool _enabled, _inlineEnabled, _completionEnabled;
  String _inlineModel = '', _completionModel = '', _reviewModel = '';
  var _customContext = false, _inlineAdvanced = false, _completionAdvanced = false;
  String? _providerIdentity;
  final _inlineExcludedHosts = <HostId>{}, _completionExcludedHosts = <HostId>{};
  late ModelProtocol _protocol;
  late ReasoningEffort _reasoningEffort;
  Timer? _checkTimer;
  var _generation = 0;
  var _working = false, _checking = false, _hasKey = false, _keyError = false, _removeKey = false, _conflict = false;
  String? _identity, _error;
  FormSaveController? _saveController;
  late final _saveEntry = FormSaveEntry(
    dirty: () => _dirty,
    canSave: () => !_working && !_initial.loadFailed && !_credentialBlocked && !_conflict,
    save: () async {
      await _save();
      return mounted && !_dirty && _error == null && !_conflict;
    },
    reset: _reset,
    context: () => mounted ? context : null,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = FormSaveScope.maybeOf(context);
    if (identical(controller, _saveController)) return;
    _saveController?.unregister(_saveEntry);
    _saveController = controller;
    controller?.register(_saveEntry);
  }

  AiCredentials get _credentials => ref.read(aiCredentialsProvider);

  ModelProfile? get _profile {
    try {
      return ModelProfile(
        protocol: _protocol,
        endpoint: _endpoint.text.trim(),
        model: _model.text.trim(),
        tools: true,
        contextWindow: int.tryParse(_contextWindow.text) ?? 0,
        maxOutputTokens: int.tryParse(_maxOutput.text) ?? 0,
        reasoningEffort: _reasoningEffort,
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

  String? get _draftProvider {
    try {
      return jsonEncode([_protocol.name, ModelProfile.normalizeEndpoint(_endpoint.text.trim())]);
    } on FormatException {
      return null;
    }
  }

  String? get _catalogCredential => _removeKey ? null : _identity;

  void _selectModel(String value, {bool inline = false, bool completion = false, bool review = false}) {
    setState(() {
      if (inline) {
        _inlineModel = value;
      } else if (completion) {
        _completionModel = value;
      } else if (review) {
        _reviewModel = value;
      } else {
        _model.text = value;
        if (_inlineModel.isEmpty) _inlineModel = value;
        if (_completionModel.isEmpty) _completionModel = value;
        _identity ??= _draftIdentity;
      }
      _error = null;
    });
  }

  bool get _emptyProfile => _endpoint.text.trim().isEmpty && _model.text.trim().isEmpty;
  // The key is optional: a pending or failed presence check must not block unrelated AI settings.
  bool get _credentialBlocked => (_checking || _keyError) && (_key.text.isNotEmpty || _removeKey);
  bool get _dirty =>
      _enabled != _initial.enabled ||
      _inlineEnabled != _initial.inlineEnabled ||
      _completionEnabled != _initial.completionEnabled ||
      !setEquals(_inlineExcludedHosts, _initial.inlineExcludedHosts) ||
      !setEquals(_completionExcludedHosts, _initial.completionExcludedHosts) ||
      _inlineModel != (_initial.inlineModel ?? _initial.profile?.model ?? '') ||
      _completionModel != (_initial.completionModel ?? _initial.profile?.model ?? '') ||
      _reviewModel != (_initial.reviewModel ?? '') ||
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
    _inlineExcludedHosts
      ..clear()
      ..addAll(config.inlineExcludedHosts);
    _completionExcludedHosts
      ..clear()
      ..addAll(config.completionExcludedHosts);
    _protocol = config.profile?.protocol ?? ModelProtocol.openai;
    _reasoningEffort = config.profile?.reasoningEffort ?? ReasoningEffort.modelDefault;
    _endpoint.text = config.profile?.endpoint ?? '';
    _model.text = config.profile?.model ?? '';
    _inlineModel = config.inlineModel ?? config.profile?.model ?? '';
    _completionModel = config.completionModel ?? config.profile?.model ?? '';
    _reviewModel = config.reviewModel ?? '';
    _contextWindow.text = '${config.profile?.contextWindow ?? 1000000}';
    _customContext = !{1000000, 256000}.contains(int.tryParse(_contextWindow.text));
    _maxOutput.text = '${config.profile?.maxOutputTokens ?? 4096}';
    _key.clear();
    _identity = _draftIdentity;
    _providerIdentity = _draftProvider;
    _checking = _identity != null;
    _hasKey = _keyError = _removeKey = _conflict = false;
    _error = null;
  }

  @override
  void dispose() {
    _saveController?.unregister(_saveEntry);
    _checkTimer?.cancel();
    _generation++;
    for (final controller in [_endpoint, _model, _key, _contextWindow, _maxOutput]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed({bool identity = false}) {
    final nextProvider = _draftProvider;
    if (identity && nextProvider != _providerIdentity) {
      _checkTimer?.cancel();
      _generation++;
      _providerIdentity = nextProvider;
      _identity = _draftIdentity;
      _hasKey = _keyError = _removeKey = false;
      _checking = _identity != null;
      if (_identity != null) {
        _checkTimer = Timer(const Duration(milliseconds: 250), _checkKey);
      }
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
    if (_working || (next.revision == _initial.revision && next.loadFailed == _initial.loadFailed)) {
      return;
    }
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
        credentialChanged = true;
        if (remove) {
          await _credentials.clear(identity);
          if (_identity != null && _identity != identity) {
            await _credentials.clear(_identity!);
          }
        } else {
          await _credentials.save(identity, Secret(key));
        }
        _identity = identity;
        if (mounted) {
          _key.clear();
          _hasKey = !remove;
          _removeKey = false;
        }
      }
      if (profile != null &&
          !remove &&
          key.isEmpty &&
          _hasKey &&
          _identity != null &&
          _identity != identity &&
          _providerIdentity == _draftProvider) {
        await preserveModelKey(_credentials, _identity!, profile);
        credentialChanged = true;
        _identity = identity;
      }
      await notifier.save(
        enabled: enabled,
        profile: profile,
        expectedRevision: revision,
        inlineEnabled: _inlineEnabled,
        completionEnabled: _completionEnabled,
        inlineExcludedHosts: _inlineExcludedHosts,
        completionExcludedHosts: _completionExcludedHosts,
        inlineModel: _inlineModel.isEmpty ? profile?.model : _inlineModel,
        completionModel: _completionModel.isEmpty ? profile?.model : _completionModel,
        reviewModel: _reviewModel.isEmpty ? null : _reviewModel,
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

  Widget _hostFilter({
    required String feature,
    required bool expanded,
    required Set<HostId> excluded,
    required bool blocked,
    required ValueChanged<bool> onExpanded,
  }) {
    final l = AppLocalizations.of(context);
    final hosts = ref.watch(aiTerminalHostsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            expanded: expanded,
            child: TextButton.icon(
              key: ValueKey('ai-config-$feature-advanced'),
              onPressed: () => onExpanded(!expanded),
              icon: Icon(expanded ? Icons.expand_less_rounded : Icons.chevron_right_rounded, size: 18),
              label: Text(l.aiConfigFeatureAdvanced),
            ),
          ),
        ),
        if (expanded) ...[
          Text(l.aiConfigAvailableHosts, style: Theme.of(context).textTheme.bodySmall),
          for (final host in hosts)
            AppToggleRow(
              key: ValueKey('ai-config-$feature-host-${host.id.value}'),
              title: host.label,
              value: !excluded.contains(host.id),
              checkbox: true,
              onChanged: blocked
                  ? null
                  : (selected) => setState(() {
                      if (selected) {
                        excluded.remove(host.id);
                      } else {
                        excluded.add(host.id);
                      }
                    }),
            ),
          if (hosts.isEmpty) Text(l.aiConfigFeatureNoHosts, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(aiConfigurationProvider, _configurationChanged);
    final config = ref.watch(aiConfigurationProvider);
    final effective = ref.watch(effectiveAgentProfileProvider);
    final reviewDefault =
        effective != null && _draftProvider == jsonEncode([effective.protocol.name, effective.endpoint])
        ? effective.model
        : _model.text;
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    _saveController?.changed();
    final blocked = _working || config.loadFailed || (_saveController?.busy ?? false);
    final activeRuntime = ref.exists(agentRuntimeProvider) ? ref.watch(agentRuntimeProvider) : null;
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
              AppOption(ModelProtocol.responses, l.aiConfigResponses),
            ],
            onChanged: blocked
                ? null
                : (v) {
                    _protocol = v;
                    _changed(identity: true);
                  },
          ),
          gap,
          AppFormField(
            label: l.aiConfigEndpoint,
            helperText: l.aiConfigEndpointHint,
            child: TextFormField(
              key: const ValueKey('ai-config-endpoint'),
              controller: _endpoint,
              enabled: !blocked,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: AppFormField.decoration(context),
              validator: (_) => _emptyProfile && !_enabled || _profile != null ? null : l.aiConfigInvalid,
              onChanged: (_) => _changed(identity: true),
            ),
          ),
          gap,
          AppFormField(
            label: l.aiConfigApiKeyOptional,
            child: TextField(
              key: const ValueKey('ai-config-key'),
              controller: _key,
              enabled: !blocked && !_checking && !_keyError && _draftProvider != null,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: AppFormField.decoration(context),
              onChanged: (_) => setState(() {
                _removeKey = false;
                _error = null;
              }),
            ),
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
          AiModelPicker(
            key: const ValueKey('ai-config-model'),
            value: _model.text,
            label: l.aiConfigAgentModel,
            protocol: _protocol,
            endpoint: _endpoint.text.trim(),
            credentialIdentity: _catalogCredential,
            draftKey: _key.text.isEmpty ? null : Secret(_key.text),
            onChanged: blocked || _draftProvider == null ? null : _selectModel,
          ),
          gap,
          AiModelPicker(
            key: const ValueKey('ai-config-review-model'),
            value: _reviewModel.isEmpty ? reviewDefault : _reviewModel,
            label: l.aiConfigReviewModel,
            protocol: _protocol,
            endpoint: _endpoint.text.trim(),
            credentialIdentity: _catalogCredential,
            draftKey: _key.text.isEmpty ? null : Secret(_key.text),
            onChanged: blocked || _draftProvider == null ? null : (value) => _selectModel(value, review: true),
          ),
          gap,
          AppFormField(
            label: l.aiReasoningEffort,
            child: ListenableBuilder(
              listenable: Listenable.merge([activeRuntime]),
              builder: (context, _) => AppSelect<ReasoningEffort>(
                key: const ValueKey('ai-config-reasoning'),
                value: _reasoningEffort,
                options: [
                  AppOption(ReasoningEffort.modelDefault, l.aiReasoningDefault),
                  AppOption(ReasoningEffort.off, l.aiReasoningOff),
                  AppOption(ReasoningEffort.low, l.aiReasoningLow),
                  AppOption(ReasoningEffort.medium, l.aiReasoningMedium),
                  AppOption(ReasoningEffort.high, l.aiReasoningHigh),
                ],
                onChanged: blocked || (activeRuntime?.busy ?? false)
                    ? null
                    : (value) => setState(() => _reasoningEffort = value),
              ),
            ),
          ),
          gap,
          Text(l.aiConfigAdvanced, style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = ((constraints.maxWidth + Space.md) / (210 + Space.md)).floor().clamp(
                1,
                _customContext ? 3 : 2,
              );
              final width = (constraints.maxWidth - Space.md * (columns - 1)) / columns;
              return Wrap(
                spacing: Space.md,
                runSpacing: Space.md,
                children: [
                  SizedBox(
                    width: width,
                    child: AppFormField(
                      label: l.aiConfigContextWindow,
                      child: AppSelect<int>(
                        key: const ValueKey('ai-config-context-preset'),
                        value: _customContext ? -1 : int.parse(_contextWindow.text),
                        options: [
                          const AppOption(1000000, '1M'),
                          const AppOption(256000, '256K'),
                          AppOption(-1, l.aiConfigContextCustom),
                        ],
                        onChanged: blocked
                            ? null
                            : (value) => setState(() {
                                _customContext = value == -1;
                                if (!_customContext) {
                                  _contextWindow.text = '$value';
                                }
                                _error = null;
                              }),
                      ),
                    ),
                  ),
                  if (_customContext)
                    SizedBox(
                      width: width,
                      child: AppFormField(
                        label: l.aiConfigContextWindow,
                        child: TextFormField(
                          key: const ValueKey('ai-config-context-custom'),
                          controller: _contextWindow,
                          enabled: !blocked,
                          keyboardType: TextInputType.number,
                          decoration: AppFormField.decoration(context),
                          validator: (_) => _profile == null ? l.aiConfigInvalid : null,
                          onChanged: (_) => _changed(),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: width,
                    child: AppFormField(
                      label: l.aiConfigMaxOutput,
                      child: TextFormField(
                        key: const ValueKey('ai-config-max-output'),
                        controller: _maxOutput,
                        enabled: !blocked,
                        keyboardType: TextInputType.number,
                        decoration: AppFormField.decoration(context),
                        validator: (_) => _emptyProfile && !_enabled || _profile != null ? null : l.aiConfigInvalid,
                        onChanged: (_) => _changed(),
                      ),
                    ),
                  ),
                ],
              );
            },
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
          AiModelPicker(
            key: const ValueKey('ai-config-inline-model'),
            value: _inlineModel,
            label: l.aiConfigInlineModel,
            protocol: _protocol,
            endpoint: _endpoint.text.trim(),
            credentialIdentity: _catalogCredential,
            draftKey: _key.text.isEmpty ? null : Secret(_key.text),
            onChanged: blocked || _draftProvider == null ? null : (value) => _selectModel(value, inline: true),
          ),
          if (_inlineEnabled) ...[
            const SizedBox(height: Space.xs),
            _hostFilter(
              feature: 'inline',
              expanded: _inlineAdvanced,
              excluded: _inlineExcludedHosts,
              blocked: blocked,
              onExpanded: (value) => setState(() => _inlineAdvanced = value),
            ),
          ],
          gap,
          AppToggleRow(
            key: const ValueKey('ai-config-completion'),
            title: l.aiConfigCompletion,
            value: _completionEnabled,
            onChanged: blocked || !_enabled || _profile == null ? null : (v) => setState(() => _completionEnabled = v),
          ),
          const SizedBox(height: Space.xs),
          Text(
            l.aiConfigCompletionHint,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: Space.sm),
          AiModelPicker(
            key: const ValueKey('ai-config-completion-model'),
            value: _completionModel,
            label: l.aiConfigCompletionModel,
            protocol: _protocol,
            endpoint: _endpoint.text.trim(),
            credentialIdentity: _catalogCredential,
            draftKey: _key.text.isEmpty ? null : Secret(_key.text),
            onChanged: blocked || _draftProvider == null ? null : (value) => _selectModel(value, completion: true),
          ),
          if (_completionEnabled) ...[
            const SizedBox(height: Space.xs),
            _hostFilter(
              feature: 'completion',
              expanded: _completionAdvanced,
              excluded: _completionExcludedHosts,
              blocked: blocked,
              onExpanded: (value) => setState(() => _completionAdvanced = value),
            ),
          ],
          if (_error != null || _conflict) ...[
            const SizedBox(height: Space.sm),
            Text(_error ?? l.aiConfigConflict, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_saveController == null) ...[
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
        ],
      ),
    );
  }
}
