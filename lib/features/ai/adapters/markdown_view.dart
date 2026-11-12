import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../design/theme.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';

/// Model text is display data; images never load and only clicked web links may leave the app.
class AiMarkdown extends StatelessWidget {
  const AiMarkdown({
    super.key,
    required this.data,
    this.openLink = openExternal,
    this.executionReferences = const {},
    this.onExecution,
  });

  final String data;
  final Future<bool> Function(String) openLink;
  final Map<String, String> executionReferences;
  final ValueChanged<String>? onExecution;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme.bodyMedium;
    final codeTint = scheme.primary.withValues(alpha: .18);
    final codeBackground = Color.alphaBlend(codeTint, scheme.surface);
    final code = mono(context, theme.textTheme.bodySmall).copyWith(color: scheme.onSurface);
    return DefaultSelectionStyle.merge(
      selectionColor: textSelectionColor(scheme, overlay: codeTint),
      child: MarkdownBody(
        data: data,
        selectable: false,
        fitContent: false,
        syntaxHighlighter: _CodeTextStyle(code),
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: text,
          h1: theme.textTheme.titleMedium,
          h2: theme.textTheme.titleSmall,
          h3: theme.textTheme.titleSmall,
          h4: theme.textTheme.labelLarge,
          h5: theme.textTheme.labelLarge,
          h6: theme.textTheme.labelMedium,
          a: text?.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
          // Selection is painted before text backgrounds, so this fill must stay translucent.
          code: code.copyWith(backgroundColor: codeTint),
          blockSpacing: Space.sm,
          listIndent: Space.lg,
          blockquotePadding: const EdgeInsets.all(Space.sm),
          blockquoteDecoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border(left: BorderSide(color: scheme.outlineVariant, width: 2)),
          ),
          codeblockPadding: const EdgeInsets.all(Space.sm),
          codeblockDecoration: BoxDecoration(color: codeBackground, borderRadius: BorderRadius.circular(Radii.control)),
          tableHead: theme.textTheme.labelMedium,
          tableBody: theme.textTheme.bodySmall,
          tableColumnWidth: const IntrinsicColumnWidth(),
          tableCellsPadding: const EdgeInsets.all(Space.sm),
          tableBorder: TableBorder.all(color: scheme.outlineVariant),
          horizontalRuleDecoration: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
        ),
        builders: {if (onExecution != null) 'code': _ExecutionReferenceBuilder(executionReferences, onExecution!)},
        imageBuilder: (_, _, alt) => Text(alt ?? '', style: text?.copyWith(color: scheme.onSurfaceVariant)),
        onTapLink: (_, href, _) {
          final uri = href == null ? null : Uri.tryParse(href);
          if (uri == null ||
              !const {'http', 'https'}.contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty) {
            return;
          }
          unawaited(openLink(uri.toString()));
        },
      ),
    );
  }
}

class _CodeTextStyle extends SyntaxHighlighter {
  _CodeTextStyle(this.style);
  final TextStyle style;

  @override
  TextSpan format(String source) => TextSpan(text: source, style: style);
}

class _ExecutionReferenceBuilder extends MarkdownElementBuilder {
  _ExecutionReferenceBuilder(this.references, this.onExecution);
  final Map<String, String> references;
  final ValueChanged<String> onExecution;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final reference = element.textContent;
    // Block code carries a trailing newline; only exact single-line IDs are navigation targets.
    if (reference.contains('\n')) return null;
    final execution = references[reference];
    if (execution == null) return null;
    final theme = Theme.of(context);
    return Tooltip(
      message: reference,
      child: TextButton(
        onPressed: () => onExecution(execution),
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          backgroundColor: theme.colorScheme.primaryContainer,
          textStyle: theme.textTheme.bodySmall,
        ),
        child: Text(AppLocalizations.of(context).aiAgentExecutionRecord),
      ),
    );
  }
}
