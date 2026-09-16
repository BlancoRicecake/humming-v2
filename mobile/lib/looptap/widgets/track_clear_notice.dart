import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A brief, non-blocking confirmation. The editor toolbar also keeps Undo.
void showTrackClearNotice(
  BuildContext context, {
  required String message,
  required String undoLabel,
  required VoidCallback onUndo,
}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: LT.t1)),
        behavior: SnackBarBehavior.floating,
        width: math.min(420, MediaQuery.sizeOf(context).width - 32),
        backgroundColor: LT.surface3,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LTRadius.control),
          side: const BorderSide(color: LT.borderStrong),
        ),
        duration: const Duration(seconds: 4),
        // Flutter otherwise makes snackbars with an action persistent.
        persist: false,
        action: SnackBarAction(
          label: undoLabel,
          textColor: LT.lime,
          onPressed: onUndo,
        ),
      ),
    );
}
