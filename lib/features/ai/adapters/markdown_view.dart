import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../design/theme.dart';
import '../../../foundation/open_external.dart';

/// Model text is display data; images never load and only clicked web links may leave the app.
class AiMarkdown extends StatelessWidget {
  const AiMarkdown({super.key, required this.data, this.openLink = openExternal});

  final String data;
  final Future<bool> Function(String) openLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme.bodyMedium;
    return MarkdownBody(
      data: data,
      selectable: false,
      fitContent: false,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: text,
        h1: theme.textTheme.titleMedium,
        h2: theme.textTheme.titleSmall,
        h3: theme.textTheme.titleSmall,
        h4: theme.textTheme.labelLarge,
        h5: theme.textTheme.labelLarge,
        h6: theme.textTheme.labelMedium,
        a: text?.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
        code: mono(context, theme.textTheme.bodySmall).copyWith(backgroundColor: scheme.surfaceContainerHigh),
        blockSpacing: Space.sm,
        listIndent: Space.lg,
        blockquotePadding: const EdgeInsets.all(Space.sm),
        blockquoteDecoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border(left: BorderSide(color: scheme.outlineVariant, width: 2)),
        ),
        codeblockPadding: const EdgeInsets.all(Space.sm),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        tableHead: theme.textTheme.labelMedium,
        tableBody: theme.textTheme.bodySmall,
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableCellsPadding: const EdgeInsets.all(Space.sm),
        tableBorder: TableBorder.all(color: scheme.outlineVariant),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
      ),
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
    );
  }
}
