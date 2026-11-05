// Small JSON files written atomically (announcements cache / read state,
// 2026-10-30). The lessons of the cloud-link review (C4) built in:
// - one read-modify-write at a time per store, holding nothing once idle;
// - a unique temp file per write;
// - the temp file REPLACES the target by rename, retried briefly when
//   Windows refuses for a moment (errno 5: an indexer / antivirus / reader
//   has the target open) — the target is never deleted first, so a failed
//   write leaves the previous content intact and removes its temp file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class AtomicJsonFile {
  AtomicJsonFile(this.file);
  final File file;

  Future<void>? _tail;
  var _active = 0;
  static var _seq = 0;

  /// Rename seam for tests (a Windows refusal can't be produced on demand).
  @visibleForTesting
  static Future<void> Function(File tmp, String target)? debugRename;

  /// One operation at a time on this file.
  Future<T> serial<T>(Future<T> Function() op) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    _active++;
    try {
      if (previous != null) await previous;
      return await op();
    } finally {
      if (--_active == 0) _tail = null;
      done.complete();
    }
  }

  /// The decoded content, or null when missing / unreadable (never throws).
  Future<Object?> read() async {
    try {
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Replace the content (call inside [serial] for read-modify-write).
  Future<void> write(Object? json) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.$pid-${_seq++}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(json), flush: true);
      for (var attempt = 0; ; attempt++) {
        try {
          final rename = debugRename;
          if (rename != null) {
            await rename(tmp, file.path);
          } else {
            await tmp.rename(file.path);
          }
          return;
        } on FileSystemException {
          if (attempt >= 8) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
        }
      }
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
