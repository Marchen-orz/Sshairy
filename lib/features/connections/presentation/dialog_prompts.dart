import 'package:flutter/material.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/secret.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/known_keys.dart';
import '../domain/prompts.dart';

class DialogPrompts implements ConnectPrompts {
  DialogPrompts(this.context);
  final BuildContext context;

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt p) async {
    // The tab may have been closed while the attempt was still running.
    if (!context.mounted) return TrustChoice.reject;
    final l = AppLocalizations.of(context);
    final changed = p.check is KeyChanged;
    final monoStyle = mono(context, TextStyle(color: Theme.of(context).colorScheme.onSurface));
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          SelectableText(value, style: monoStyle),
        ],
      ),
    );
    final choice = await showAppDialog<TrustChoice>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AppDialog(
        width: 528,
        title: Text(changed ? l.hostKeyChanged : l.hostKeyUnknown),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('${p.endpoint} · ${p.type}', style: monoStyle),
              if (p.check case KeyChanged(:final saved)) ...[
                row(l.previousKey, saved),
                row(l.currentKey, p.fingerprint),
                const SizedBox(height: Space.md),
                Text(l.hostKeyChangedWarning, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ] else ...[
                row('SHA256', p.fingerprint.replaceFirst('SHA256:', '')),
                if (p.check case KeyUnknown(:final others) when others.isNotEmpty)
                  for (final e in others.entries) row('${l.previousKey} · ${e.key}', e.value),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, TrustChoice.reject), child: Text(l.cancel)),
          if (!changed) TextButton(onPressed: () => Navigator.pop(context, TrustChoice.once), child: Text(l.trustOnce)),
          changed
              ? TextButton(
                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () => Navigator.pop(context, TrustChoice.save),
                  child: Text(l.replaceKey),
                )
              : FilledButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context, TrustChoice.save),
                  child: Text(l.trustSave),
                ),
        ],
      ),
    );
    return choice ?? TrustChoice.reject;
  }

  @override
  Future<SecretAnswer?> secret(SecretRequest r) async {
    if (!context.mounted) return null;
    return showAppDialog<SecretAnswer>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SecretDialog(request: r),
    );
  }
}

class _SecretDialog extends StatefulWidget {
  const _SecretDialog({required this.request});
  final SecretRequest request;

  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> {
  final _input = TextEditingController();
  var _remember = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final l = AppLocalizations.of(context);
    final label = switch (r.kind) {
      SecretKind.password => l.password,
      SecretKind.proxyPassword => l.proxyPassword,
      SecretKind.passphrase => l.passphrase,
      SecretKind.challenge => r.text,
    };
    void submit() => Navigator.pop(context, SecretAnswer(Secret(_input.text), remember: _remember));
    return AppDialog(
      width: 408,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (r.target.isNotEmpty) ...[SelectableText(r.target), const SizedBox(height: Space.md)],
            TextField(
              controller: _input,
              autofocus: true,
              obscureText: !r.echo,
              decoration: InputDecoration(labelText: label),
              onSubmitted: (_) => submit(),
            ),
            if (r.canRemember)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: AppToggleRow(
                  checkbox: true,
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v),
                  title: l.remember,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: submit, child: Text(l.connect)),
      ],
    );
  }
}
