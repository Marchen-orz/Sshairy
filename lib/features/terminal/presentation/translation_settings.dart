import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/form_save.dart';
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
  late TranslationConfig _initial;
  late TranslationProvider _provider;
  late bool _deepLFree;
  late int _revision;
  final _endpoint = TextEditingController();
  final _model = TextEditingController();
  final _region = TextEditingController();
  final _email = TextEditingController();
  final _key = TextEditingController();
  final _form = GlobalKey<FormState>();
  Timer? _checkTimer;
  var _checkGeneration = 0;
  var _busy = false, _saving = false, _saveFailed = false, _conflict = false;
  var _checking = false, _hasKey = false, _keyError = false, _removeKey = false;
  String? _checkedIdentity, _error;
  (int, String)? _ownWrite;
  FormSaveController? _saveController;
  late final _saveEntry = FormSaveEntry(
    dirty: () => _dirty,
    canSave: () => !_busy && !_saving && !_checking && !_keyError && !_conflict,
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

  bool get _working => _busy || _saving;
  bool get _dirty => _key.text.isNotEmpty || _removeKey || jsonEncode(_draft.toJson()) != jsonEncode(_initial.toJson());

  TranslationConfig get _draft => TranslationConfig(
    provider: _provider,
    endpoint: _provider == TranslationProvider.openAi ? _endpoint.text.trim() : '',
    model: _provider == TranslationProvider.openAi ? _model.text.trim() : '',
    region: _provider == TranslationProvider.microsoft ? _region.text.trim() : '',
    myMemoryEmail: _provider == TranslationProvider.myMemory ? _email.text.trim() : '',
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
    _load(ref.read(settingsProvider).get(SettingKeys.completionTranslationConfig));
    _checkCredential();
  }

  @override
  void dispose() {
    _saveController?.unregister(_saveEntry);
    _checkTimer?.cancel();
    for (final controller in [_endpoint, _model, _region, _email, _key]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _load(TranslationConfig config) {
    _checkTimer?.cancel();
    _checkGeneration++;
    _initial = config;
    _revision = ref.read(settingsProvider.notifier).revision;
    _provider = config.provider;
    _deepLFree = config.deepLFree;
    _endpoint.text = config.endpoint;
    _model.text = config.model;
    _region.text = config.region;
    _email.text = config.myMemoryEmail;
    _key.clear();
    _checkedIdentity = null;
    _hasKey = _keyError = _removeKey = _conflict = false;
    _error = null;
    _checking = _identity != null;
  }

  void _settingsChanged(Settings? previous, Settings next) {
    final revision = ref.read(settingsProvider.notifier).revision;
    if (_ownWrite case (final before, final expected)
        when !_conflict && _revision == before && revision == before + 1 && jsonEncode(next.toJson()) == expected) {
      _revision = revision;
      return;
    }
    if (revision == _revision) return;
    if (!_busy &&
        !_conflict &&
        jsonEncode(next.get(SettingKeys.completionTranslationConfig).toJson()) == jsonEncode(_initial.toJson())) {
      _revision = revision;
      return;
    }
    if (!_dirty && !_busy) {
      final config = next.get(SettingKeys.completionTranslationConfig);
      if (jsonEncode(config.toJson()) == jsonEncode(_initial.toJson())) {
        _revision = revision;
      } else {
        setState(() => _load(config));
        _checkCredential();
      }
    } else {
      setState(() => _conflict = true);
    }
  }

  void _reset() {
    _form.currentState?.reset();
    setState(() => _load(ref.read(settingsProvider).get(SettingKeys.completionTranslationConfig)));
    _checkCredential();
  }

  void _changed() => setState(() => _error = null);

  Future<void> _saveSetting<T>(SettingDef<T> setting, T value) async {
    if (_working) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    final notifier = ref.read(settingsProvider.notifier);
    try {
      await notifier.saved;
      if (!mounted) return;
      _ownWrite = (notifier.revision, jsonEncode(ref.read(settingsProvider).copyWith({setting.key: value}).toJson()));
      await notifier.set(setting, value);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      _ownWrite = null;
      if (mounted) setState(() => _saving = false);
    }
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
    if (_working || _checking || _keyError || !_dirty || !_form.currentState!.validate()) return;
    final l = AppLocalizations.of(context);
    final config = _draft;
    if (!config.isValid) return;
    final identity = _identity;
    final revision = _revision;
    final notifier = ref.read(settingsProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await notifier.saved;
      if (!mounted) return;
      if (_conflict || notifier.revision != revision) {
        setState(() {
          _conflict = true;
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
      _ownWrite = (
        revision,
        jsonEncode(ref.read(settingsProvider).copyWith({SettingKeys.completionTranslationConfig.key: config}).toJson()),
      );
      final result = await notifier.patch({
        SettingKeys.completionTranslationConfig.key: config.toJson(),
      }, expectedRevision: revision);
      if (!mounted) return;
      if (result is Err<void>) {
        setState(() => _error = l.translationSaveFailed);
        return;
      }
      setState(() => _load(ref.read(settingsProvider).get(SettingKeys.completionTranslationConfig)));
      _checkCredential();
    } catch (_) {
      if (mounted) setState(() => _error = l.translationSaveFailed);
    } finally {
      _ownWrite = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider, _settingsChanged);
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    const gap = SizedBox(height: Space.lg);
    final hasCredentials = _provider != TranslationProvider.myMemory;
    final error = _error ?? (_conflict ? l.translationConflict : null);
    _saveController?.changed();
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppToggleRow(
            title: l.completionTranslation,
            subtitle: l.completionTranslationHint,
            value: settings.get(SettingKeys.completionTranslation),
            onChanged: _working ? null : (value) => _saveSetting(SettingKeys.completionTranslation, value),
          ),
          const SizedBox(height: Space.sm),
          AppSelect<TranslationProvider>(
            value: _provider,
            options: [
              for (final provider in TranslationProvider.values) AppOption(provider, _providerLabel(provider, l)),
            ],
            onChanged: _working
                ? null
                : (value) {
                    setState(() {
                      _provider = value;
                      _error = null;
                    });
                    _identityChanged();
                  },
          ),
          if (_provider == TranslationProvider.myMemory) ...[
            const SizedBox(height: Space.sm),
            Text(l.translationMyMemoryHint, style: theme.textTheme.bodySmall),
            gap,
            TextFormField(
              controller: _email,
              enabled: !_working,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l.translationEmail,
                helperText: l.translationEmailHint,
                helperMaxLines: 3,
              ),
              validator: (value) =>
                  TranslationConfig.validMyMemoryEmail(value!.trim()) ? null : l.translationEmailInvalid,
              onChanged: (_) => _changed(),
            ),
          ],
          if (_provider == TranslationProvider.deepL) ...[
            gap,
            AppToggleRow(
              title: l.translationDeepLFree,
              value: _deepLFree,
              onChanged: _working
                  ? null
                  : (value) {
                      setState(() {
                        _deepLFree = value;
                        _error = null;
                      });
                      _identityChanged();
                    },
            ),
          ],
          if (_provider == TranslationProvider.microsoft) ...[
            gap,
            TextFormField(
              controller: _region,
              enabled: !_working,
              decoration: InputDecoration(labelText: l.translationRegion),
              validator: (value) => TranslationConfig.validRegion(value!.trim()) ? null : l.translationRegionInvalid,
              onChanged: (_) {
                _changed();
                _identityChanged(debounce: true);
              },
            ),
          ],
          if (_provider == TranslationProvider.openAi) ...[
            gap,
            TextFormField(
              controller: _endpoint,
              enabled: !_working,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l.translationEndpoint,
                helperText: l.translationEndpointHint,
                helperMaxLines: 2,
              ),
              validator: (value) =>
                  TranslationConfig.validEndpoint(value!.trim()) ? null : l.translationEndpointInvalid,
              onChanged: (_) {
                _changed();
                _identityChanged(debounce: true);
              },
            ),
            gap,
            TextFormField(
              controller: _model,
              enabled: !_working,
              autocorrect: false,
              decoration: InputDecoration(labelText: l.translationModel),
              validator: (value) => TranslationConfig.validModel(value!.trim()) ? null : l.translationModelInvalid,
              onChanged: (_) => _changed(),
            ),
          ],
          if (hasCredentials) ...[
            gap,
            TextField(
              controller: _key,
              enabled: !_working && !_checking && !_keyError && _identity != null,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: l.translationApiKey),
              onChanged: (_) => setState(() {
                _removeKey = false;
                _error = null;
              }),
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
                  onPressed: _working
                      ? null
                      : () => setState(() {
                          _removeKey = true;
                          _key.clear();
                          _error = null;
                        }),
                  child: Text(l.translationRemoveKey),
                ),
              ),
          ],
          if (error != null) ...[
            const SizedBox(height: Space.sm),
            Text(error, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_saveController == null) ...[
            const SizedBox(height: Space.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _working ? null : _reset, child: Text(l.cancel)),
                const SizedBox(width: Space.sm),
                FilledButton(
                  onPressed: _working || _checking || _keyError || _conflict || !_dirty ? null : _save,
                  child: Text(l.save),
                ),
              ],
            ),
          ],
          gap,
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
                onChanged: _working
                    ? null
                    : (value) => _saveSetting(SettingKeys.completionTranslationConcurrency, value),
              ),
            ],
          ),
          if (_saveFailed) Text(l.errSave, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
    );
  }
}
