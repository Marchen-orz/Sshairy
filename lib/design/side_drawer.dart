import 'package:flutter/material.dart';

import 'theme.dart';

/// Edit drawer from docs/UI.md §1: slides in from the right, Esc or the barrier closes it.
Future<T?> showSideDrawer<T>(BuildContext context, WidgetBuilder builder) => showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) => Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 400,
          height: double.infinity,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Padding(padding: const EdgeInsets.all(Space.xl), child: builder(context)),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: CurvedAnimation(parent: animation, curve: Curves.easeOut)
            .drive(Tween(begin: const Offset(1, 0), end: Offset.zero)),
        child: child,
      ),
    );
