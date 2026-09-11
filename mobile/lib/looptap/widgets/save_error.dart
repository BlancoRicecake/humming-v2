import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

void showSongSaveError(BuildContext context) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(L10n.of(context).ltSongSaveFailed)));
}
