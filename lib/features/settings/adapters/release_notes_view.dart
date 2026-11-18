import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../design/theme.dart';
import '../../../foundation/open_external.dart';

/// Release bodies are Markdown, and the dialog stacks several of them, so the type stays compact.
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme.bodySmall;
    final codeTint = scheme.primary.withValues(alpha: .18);
    return MarkdownBody(
      data: data,
      selectable: true,
      fitContent: false,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: text,
        h1: theme.textTheme.titleSmall,
        h2: theme.textTheme.titleSmall,
        h3: theme.textTheme.labelLarge,
        h4: theme.textTheme.labelLarge,
        h5: theme.textTheme.labelMedium,
        h6: theme.textTheme.labelMedium,
        a: text?.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
        listBullet: text,
        // Selection is painted before text backgrounds, so this fill must stay translucent.
        code: mono(context, text).copyWith(backgroundColor: codeTint),
        blockSpacing: Space.xs,
        listIndent: Space.md,
        listBulletPadding: const EdgeInsets.only(right: Space.xs),
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
        unawaited(openExternal(uri.toString()));
      },
    );
  }
}
