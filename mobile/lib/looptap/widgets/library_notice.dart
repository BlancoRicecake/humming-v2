import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../state/loop_storage.dart';
import '../state/loop_store.dart';
import '../theme/tokens.dart';

/// Storage audit 2026-10-30: what loading the song library had to do (a
/// restored backup, skipped songs, an unreadable or newer file) is told on
/// the library instead of only a debug log. On the desktop the folder that
/// holds songs.json is shown so the user can find (and back up) the files.
/// Dismissed for this session; the next launch re-checks.
class LibraryNoticeBanner extends StatelessWidget {
  const LibraryNoticeBanner({super.key});

  static bool get _desktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LoopStore>();
    final issue = store.loadIssue;
    if (issue == LoadIssue.none) return const SizedBox.shrink();
    final l = L10n.of(context);
    final message = switch (issue) {
      LoadIssue.recoveredFromBackup => l.ltLibraryRecovered,
      LoadIssue.skippedSongs => l.ltLibrarySkipped,
      LoadIssue.unreadable => l.ltLibraryUnreadable,
      LoadIssue.newerSchema => l.ltLibraryNewer,
      LoadIssue.none => '',
    };
    final serious = issue != LoadIssue.recoveredFromBackup;
    return Padding(
      key: const ValueKey('library-notice'),
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                serious ? Icons.warning_amber_rounded : Icons.info_outline,
                color: serious ? LT.danger : LT.lime,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message,
                      style: const TextStyle(color: LT.t1, fontSize: 12),
                    ),
                    if (_desktop)
                      FutureBuilder<String>(
                        future: LoopStorage.libraryPath(),
                        builder:
                            (context, snap) =>
                                snap.hasData
                                    ? Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: SelectableText(
                                        l.ltLibraryFolder(snap.data!),
                                        style: const TextStyle(
                                          color: LT.t3,
                                          fontSize: 11,
                                        ),
                                      ),
                                    )
                                    : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('library-notice-close'),
                tooltip: l.close,
                icon: const Icon(Icons.close, size: 18, color: LT.t3),
                onPressed: store.dismissLoadIssue,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
