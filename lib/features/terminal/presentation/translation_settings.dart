import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/result.dart';
import '../../../foundation/secret.dart';
import '../../../l10n/app_localizations.dart';
import '../../credentials/api.dart';
import '../../settings/api.dart';

String _providerLabel(TranslationProvider provider, AppLocalizations l) => switch (provider) {
  TranslationProvider.myMemory => l.translationMyMemory,
  TranslationProvider.deepL => l.translationDeepL,
  TranslationProvider.google => l.translationGoogle,
  TranslationProvider.microsoft => l.translationMicrosoft,
  TranslationProvider.openAi => l.translationOpenAi,
};

class TranslationSettings extends ConsumerStatefulWidget {
  const TranslationSettings({super.key, required this.credentials, this.onCredentialsChanged});

  final TranslationCredentials credentials;
  final VoidCallback? onCredentialsChanged;

  @override
  ConsumerState<TranslationSettings> createState() => _TranslationSettingsState();
}

class _TranslationSettingsState extends ConsumerState<TranslationSettings> {
  var _saving = false, _saveFailed = false;

  Future<void> _save<T>(SettingDef<T> setting, T value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await ref.read(settingsProvider.notifier).set(setting, value);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final config = settings.get(SettingKeys.completionTranslationConfig);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppToggleRow(
          title: l.completionTranslation,
          subtitle: l.completionTranslationHint,
          value: settings.get(SettingKeys.completionTranslation),
          onChanged: _saving ? null : (value) => _save(SettingKeys.completionTranslation, value),
        ),
        const SizedBox(height: Space.sm),
        Row(
          children: [
            Expanded(child: Text(l.translationConcurrency)),
            const SizedBox(width: Space.md),
            AppSelect<int>(
              width: 208,
              value: settings.get(SettingKeys.completionTranslationConcurrency),
              options: [
                AppOption(0, l.translationConcurrencyAuto),
                for (var value = 1; value <= SettingKeys.completionTranslationConcurrency.max; value++)
                  AppOption(value, '$value'),
              ],
              onChanged: _saving ? null : (value) => _save(SettingKeys.completionTranslationConcurrency, value),
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _saving
                ? null
                : () => showAppDialog<void>(
                    context: context,
                    builder: (_) => _TranslationDialog(
                      initial: config,
                      revision: ref.read(settingsProvider.notifier).revision,
                      credentials: widget.credentials,
                      onCredentialsChanged: widget.onCredentialsChanged,
                    ),
                  ),
            child: Text('${l.translationService} · ${_providerLabel(config.provider, l)}'),
          ),
        ),
        if (_saveFailed) Text(l.errSave, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}

class _TranslationDialog extends ConsumerStatefulWidget {
  const _TranslationDialog({
    required this.initial,
    required this.revision,
    required this.credentials,
    this.onCredentialsChanged,
  });

  final TranslationConfig initial;
  final int revision;
  final TranslationCredentials credentials;
  final VoidCallback? onCredentialsChanged;

  @override
  ConsumerState<_TranslationDialog> createState() => _TranslationDialogState();
}

class _TranslationDialogState extends ConsumerState<_TranslationDialog> {
  late var _provider = widget.initial.provider;
  late var _deepLFree = widget.initial.deepLFree;
  late final _endpoint = TextEditingController(text: widget.initial.endpoint);
  late final _model = TextEditingController(text: widget.initial.model);
  late final _region = TextEditingController(text: widget.initial.region);
  final _key = TextEditingController();
  final _form = GlobalKey<FormState>();
  Timer? _checkTimer;
  var _checkGeneration = 0;
  var _busy = false, _checking = false, _hasKey = false, _keyError = false, _removeKey = false;
  String? _checkedIdentity, _error;

  TranslationConfig get _draft => TranslationConfig(
    provider: _provider,
    endpoint: _provider == TranslationProvider.openAi ? _endpoint.text.trim() : '',
    model: _provider == TranslationProvider.openAi ? _model.text.trim() : '',
    region: _provider == TranslationProvider.microsoft ? _region.text.trim() : '',
    deepLFree: _deepLFree,
  );

  String? get _identity {
    final config = _draft;
    if (config.provider == TranslationProvider.myMemory ||
        (config.provider == TranslationProvider.openAi && !TranslationConfig.validEndpoint(config.endpoint)) ||
        (config.provider == TranslationProvider.microsoft && !TranslationConfig.validRegion(config.region))) {
      return null;
    }
    return config.credentialId;
  }

  @override
  void initState() {
    super.initState();
    _checkCredential();
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    for (final controller in [_endpoint, _model, _region, _key]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _identityChanged({bool debounce = false}) {
    _checkTimer?.cancel();
    final identity = _identity;
    if (identity != null && identity == _checkedIdentity) return;
    _checkGeneration++;
    setState(() {
      _checkedIdentity = null;
      _hasKey = _keyError = _removeKey = false;
      _checking = identity != null;
      _key.clear();
    });
    if (debounce) {
      _checkTimer = Timer(const Duration(milliseconds: 250), _checkCredential);
    } else {
      _checkCredential();
    }
  }

  Future<void> _checkCredential() async {
    final identity = _identity;
    final generation = ++_checkGeneration;
    _checkedIdentity = identity;
    if (identity == null) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    setState(() {
      _checking = true;
      _keyError = false;
    });
    try {
      final hasKey = await widget.credentials.has(identity);
      if (!mounted || generation != _checkGeneration) return;
      setState(() {
        _hasKey = hasKey;
        _checking = false;
      });
    } catch (_) {
      if (!mounted || generation != _checkGeneration) return;
      setState(() {
        _checking = false;
        _keyError = true;
      });
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _busy || _checking || _keyError) return;
    final l = AppLocalizations.of(context);
    final config = _draft;
    if (!config.isValid) return;
    final identity = _identity;
    final notifier = ref.read(settingsProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await notifier.saved;
      if (!mounted) return;
      if (notifier.revision != widget.revision) {
        setState(() {
          _busy = false;
          _error = l.translationConflict;
        });
        return;
      }
      if (identity != null && (_key.text.isNotEmpty || _removeKey)) {
        final removing = _removeKey;
        if (removing) {
          await widget.credentials.clear(identity);
        } else {
          await widget.credentials.save(identity, Secret(_key.text));
        }
        if (mounted) {
          _key.clear();
          _hasKey = !removing;
          _removeKey = false;
        }
        widget.onCredentialsChanged?.call();
      }
      final result = await notifier.patch({
        'completionTranslationConfig': config.toJson(),
      }, expectedRevision: widget.revision);
      if (!mounted) return;
      if (result is Err<void>) {
        setState(() {
          _busy = false;
          _error = l.translationSaveFailed;
        });
        return;
      }
      setState(() => _busy = false);
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l.translationSaveFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    const gap = SizedBox(height: Space.lg);
    final hasCredentials = _provider != TranslationProvider.myMemory;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text(l.translationService),
        width: 480,
        content: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSelect<TranslationProvider>(
                  value: _provider,
                  label: l.translationProvider,
                  options: [
                    for (final provider in TranslationProvider.values) AppOption(provider, _providerLabel(provider, l)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _provider = value);
                          _identityChanged();
                        },
                ),
                if (_provider == TranslationProvider.myMemory) ...[
                  const SizedBox(height: Space.sm),
                  Text(l.translationMyMemoryHint, style: theme.textTheme.bodySmall),
                ],
                if (_provider == TranslationProvider.deepL) ...[
                  gap,
                  AppToggleRow(
                    title: l.translationDeepLFree,
                    value: _deepLFree,
                    onChanged: _busy
                        ? null
                        : (value) {
                            setState(() => _deepLFree = value);
                            _identityChanged();
                          },
                  ),
                ],
                if (_provider == TranslationProvider.microsoft) ...[
                  gap,
                  TextFormField(
                    controller: _region,
                    enabled: !_busy,
                    decoration: InputDecoration(labelText: l.translationRegion),
                    validator: (value) =>
                        TranslationConfig.validRegion(value!.trim()) ? null : l.translationRegionInvalid,
                    onChanged: (_) => _identityChanged(debounce: true),
                  ),
                ],
                if (_provider == TranslationProvider.openAi) ...[
                  gap,
                  TextFormField(
                    controller: _endpoint,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l.translationEndpoint,
                      helperText: l.translationEndpointHint,
                      helperMaxLines: 2,
                    ),
                    validator: (value) =>
                        TranslationConfig.validEndpoint(value!.trim()) ? null : l.translationEndpointInvalid,
                    onChanged: (_) => _identityChanged(debounce: true),
                  ),
                  gap,
                  TextFormField(
                    controller: _model,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: InputDecoration(labelText: l.translationModel),
                    validator: (value) =>
                        TranslationConfig.validModel(value!.trim()) ? null : l.translationModelInvalid,
                  ),
                ],
                if (hasCredentials) ...[
                  gap,
                  TextField(
                    controller: _key,
                    enabled: !_busy && !_checking && !_keyError && _identity != null,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(labelText: l.translationApiKey),
                    onChanged: (_) {
                      if (_removeKey) setState(() => _removeKey = false);
                    },
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    _checking
                        ? l.translationKeyLoading
                        : _keyError
                        ? l.translationKeyLoadFailed
                        : _removeKey
                        ? l.translationKeyRemoved
                        : _hasKey
                        ? l.translationKeySaved
                        : l.translationKeyMissing,
                    style: theme.textTheme.bodySmall?.copyWith(color: _keyError ? theme.colorScheme.error : null),
                  ),
                  if (_hasKey && !_removeKey)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _removeKey = true;
                                _key.clear();
                              }),
                        child: Text(l.translationRemoveKey),
                      ),
                    ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(l.cancel)),
          FilledButton(onPressed: _busy || _checking || _keyError ? null : _save, child: Text(l.save)),
        ],
      ),
    );
  }
}
