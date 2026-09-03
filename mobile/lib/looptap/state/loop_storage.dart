// LoopTap persistence — single JSON file <Documents>/looptap/songs.json,
// mirroring the prototype's localStorage["looptap_songs_v1"].
//
// Durability (audit C1): saves are atomic (write `songs.json.tmp`, then rename
// into place, keeping the previous good file as `songs.json.bak`). A load that
// can't parse the main file preserves it as `songs.json.corrupt-<ts>`, falls
// back to `.bak`, and decodes song-by-song so one bad entry never empties the
// library. [loadFailed] tells the store whether "empty" means "empty".
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/loop_models.dart';

class LoopStorage {
  // Documents path cache so vocal basenames can be resolved synchronously from
  // widgets/painters. Filled by [ensureDirs] (called at bootstrap + editor open).
  static String? _docsPath;

  /// Test hook: when set, this directory replaces the platform Documents dir
  /// (path_provider needs a platform channel, which unit tests don't have).
  @visibleForTesting
  static Directory? rootOverride;

  static Future<Directory> _folder() async {
    final dir = rootOverride ?? await getApplicationDocumentsDirectory();
    _docsPath = dir.path;
    final folder = Directory('${dir.path}/looptap');
    if (!await folder.exists()) await folder.create(recursive: true);
    return folder;
  }

  /// Warm the Documents-path cache + create the looptap/vocals folders.
  static Future<void> ensureDirs() async {
    final dir = (await _folder()).path;
    final vocals = Directory('$dir/vocals');
    if (!await vocals.exists()) await vocals.create(recursive: true);
  }

  /// Resolve a stored vocal file name to an absolute path. Vocal paths are
  /// persisted as basenames (absolute paths break when the iOS app container
  /// UUID changes); anything that still looks absolute passes through as-is.
  static String resolveVocal(String nameOrPath) {
    if (nameOrPath.contains('/') || nameOrPath.contains('\\')) return nameOrPath;
    final docs = _docsPath;
    if (docs == null) return nameOrPath; // cache not warm — caller's IO will fail gracefully
    return '$docs/looptap/vocals/$nameOrPath';
  }

  static Future<File> _file() async => File('${(await _folder()).path}/songs.json');
  static Future<File> _tmpFile() async => File('${(await _folder()).path}/songs.json.tmp');
  static Future<File> _bakFile() async => File('${(await _folder()).path}/songs.json.bak');
  static Future<File> _metaFile() async => File('${(await _folder()).path}/meta.json');
  static Future<File> _userFile() async => File('${(await _folder()).path}/user.json');

  // True when songs.json EXISTED but couldn't be read/parsed (and no backup
  // rescued it) — the song list is then silently empty and neither seeding nor
  // [sweepVocals] may run off it. A missing file is a legitimately empty library.
  static bool _loadFailed = false;
  static bool get loadFailed => _loadFailed;

  // Songs dropped by the lenient decoder on the last load. Their takes are
  // still on disk and still theirs — sweeping would delete them.
  static int _skippedOnLoad = 0;
  static int get skippedOnLoad => _skippedOnLoad;

  static Future<List<Song>> load() async {
    _loadFailed = false;
    _skippedOnLoad = 0;
    File? f;
    try {
      f = await _file();
      final bak = await _bakFile();
      if (!await f.exists()) {
        // A crash between "move old → .bak" and "move tmp → songs.json" leaves
        // only the backup — that IS the library, not an empty one.
        if (await bak.exists()) {
          debugPrint('[looptap] songs.json missing, restoring from .bak');
          final r = await _decodeFile(bak);
          if (r != null) return r;
        }
        return [];
      }
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return [];
      final r = Song.decodeListLenient(raw);
      _skippedOnLoad = r.skipped;
      if (r.skipped > 0) {
        debugPrint('[looptap] load: skipped ${r.skipped} unreadable song(s)');
        // keep the original around — the skipped entries may be recoverable.
        await _preserveCorrupt(f);
      }
      return r.songs;
    } catch (e) {
      debugPrint('[looptap] load failed: $e');
    }
    // main file unreadable → keep it, try the backup.
    try {
      if (f != null) await _preserveCorrupt(f, rename: true);
      final bak = await _bakFile();
      if (await bak.exists()) {
        final r = await _decodeFile(bak);
        if (r != null) {
          debugPrint('[looptap] recovered ${r.length} song(s) from .bak');
          return r;
        }
      }
    } catch (e) {
      debugPrint('[looptap] backup load failed: $e');
    }
    _loadFailed = true;
    return [];
  }

  static Future<List<Song>?> _decodeFile(File f) async {
    try {
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      final r = Song.decodeListLenient(raw);
      _skippedOnLoad = r.skipped;
      return r.songs;
    } catch (e) {
      debugPrint('[looptap] decode ${f.path.split('/').last} failed: $e');
      return null;
    }
  }

  /// Keep an unreadable/partially readable songs.json as
  /// `songs.json.corrupt-<millis>` — never silently discard user data.
  static Future<void> _preserveCorrupt(File f, {bool rename = false}) async {
    try {
      if (!await f.exists()) return;
      final dest = '${f.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      if (rename) {
        await f.rename(dest);
      } else {
        await f.copy(dest);
      }
      debugPrint('[looptap] preserved unreadable songs file as ${dest.split('/').last}');
    } catch (e) {
      debugPrint('[looptap] could not preserve corrupt songs file: $e');
    }
  }

  /// Atomic save: write the whole payload to a temp file, then swap it in.
  /// The previous songs.json survives as songs.json.bak.
  static Future<void> save(List<Song> songs) async {
    try {
      final f = await _file();
      final tmp = await _tmpFile();
      final bak = await _bakFile();
      await tmp.writeAsString(Song.encodeList(songs), flush: true);
      if (await f.exists()) {
        if (await bak.exists()) await bak.delete();
        await f.rename(bak.path);
      }
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('[looptap] save failed: $e');
    }
  }

  // ── meta (seed marker etc.) ─────────────────────────────────────────
  static Future<Map<String, dynamic>> _loadMeta() async {
    try {
      final f = await _metaFile();
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  /// Whether the demo songs were ever seeded on this install. Once true, an
  /// empty library stays empty (the user deleted everything on purpose).
  static Future<bool> seeded() async => (await _loadMeta())['seeded'] == true;

  static Future<void> markSeeded() async {
    try {
      final meta = await _loadMeta();
      meta['seeded'] = true;
      await (await _metaFile()).writeAsString(jsonEncode(meta), flush: true);
    } catch (e) {
      debugPrint('[looptap] meta save failed: $e');
    }
  }

  static Future<Map<String, String>?> loadUser() async {
    try {
      final f = await _userFile();
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return null;
    }
  }

  /// Copy a freshly-recorded vocal file into persistent storage and return its
  /// BASENAME under Documents/looptap/vocals/. Timestamped so a re-record never
  /// overwrites the take an undo snapshot still references.
  static Future<String?> copyVocal(String srcPath, String songId, String sectionId) async {
    try {
      final dir = (await _folder()).path;
      final vocals = Directory('$dir/vocals');
      if (!await vocals.exists()) await vocals.create(recursive: true);
      final ext = srcPath.contains('.') ? srcPath.substring(srcPath.lastIndexOf('.')) : '.wav';
      final name = '${songId}_${sectionId}_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(srcPath).copy('${vocals.path}/$name');
      return name;
    } catch (e) {
      debugPrint('[looptap] copyVocal failed: $e');
      return null;
    }
  }

  /// Write processed vocal audio (e.g. an autotuned take) straight into
  /// persistent storage; returns the BASENAME. [suffix] tags the variant
  /// (e.g. '_tuned') so files are tellable apart on disk.
  static Future<String?> saveVocalBytes(
      List<int> bytes, String songId, String sectionId, {String suffix = ''}) async {
    try {
      final dir = (await _folder()).path;
      final vocals = Directory('$dir/vocals');
      if (!await vocals.exists()) await vocals.create(recursive: true);
      final name = '${songId}_${sectionId}_${DateTime.now().millisecondsSinceEpoch}$suffix.wav';
      await File('${vocals.path}/$name').writeAsBytes(bytes);
      return name;
    } catch (e) {
      debugPrint('[looptap] saveVocalBytes failed: $e');
      return null;
    }
  }

  /// Delete vocal files no song references anymore (re-record leftovers,
  /// cleared tracks, deleted sections). Safe to call once the editor's undo
  /// stack is gone — i.e. on leaving the edit screen.
  static Future<void> sweepVocals(List<Song> songs) async {
    // a failed load leaves [songs] silently empty — sweeping then would
    // mass-delete takes that are still referenced by the unreadable file.
    // Likewise a partial load: the skipped songs' takes are still theirs.
    if (_loadFailed || _skippedOnLoad > 0) return;
    try {
      final vocals = Directory('${(await _folder()).path}/vocals');
      if (!await vocals.exists()) return;
      // belt and braces: an empty library legitimately has no takes to keep,
      // but if the list is empty while takes exist on disk, prefer keeping
      // them over an irreversible mass delete.
      if (songs.isEmpty && !await vocals.list().isEmpty) {
        debugPrint('[looptap] sweepVocals skipped: empty song list with takes on disk');
        return;
      }
      final referenced = <String>{};
      for (final song in songs) {
        if (song.songVocalPath != null) referenced.add(song.songVocalPath!);
        for (final sec in song.sections) {
          for (final t in sec.tracks.values) {
            final paths = <String?>[
              t.vocalPath,
              t.vocalOrigPath,
              for (final c in t.clips ?? const <VocalClip>[]) ...[c.path, c.origPath],
            ];
            for (final p in paths) {
              if (p != null) {
                final base = p.split('/').last.split('\\').last;
                referenced.add(base);
                // keep the legacy-conversion cache wav_export writes next to
                // legacy takes (see _loadVocalBytes: '<take>.cnv.wav')
                referenced.add('$base.cnv.wav');
              }
            }
          }
        }
      }
      await for (final f in vocals.list()) {
        if (f is File && !referenced.contains(f.uri.pathSegments.last)) {
          try { await f.delete(); } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[looptap] sweepVocals failed: $e');
    }
  }

  static Future<void> saveUser(Map<String, String>? user) async {
    try {
      final f = await _userFile();
      if (user == null) {
        if (await f.exists()) await f.delete();
      } else {
        await f.writeAsString(jsonEncode(user));
      }
    } catch (e) {
      debugPrint('[looptap] saveUser failed: $e');
    }
  }
}
