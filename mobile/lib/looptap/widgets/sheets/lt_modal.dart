// LoopTap — centered modal card (prototype's Sheet/overlay). Dark scrim + a
// rounded surface card, dismissible by tapping the scrim.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

Future<T?> showLtModal<T>(
  BuildContext context, {
  required Widget child,
  double width = 420,
  bool dismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'modal',
    barrierColor: Colors.black.withValues(alpha: 0.65),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (_, __, ___) => Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: LT.surface,
              borderRadius: BorderRadius.circular(LTRadius.sheet),
              border: Border.all(color: LT.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (_, anim, __, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(anim), child: child),
    ),
  );
}
