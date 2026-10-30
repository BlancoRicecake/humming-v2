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

/// songs.json was written by a newer app (schema [found] > what this build
/// knows); saving is refused so the newer data is never overwritten.
class NewerSongsSchemaException implements Exception {
  const NewerSongsSchemaException(this.found);
  final int found;
  @override
  String toString() =>
      'songs.json schema v$found is newer than v${Song.kSchemaVersion}';
}

/// What the last [LoopStorage.load] had to do (storage audit 2026-10-30): the
/// song list tells the user instead of only a debug log.
enum LoadIssue {
  none,

  /// songs.json was missing or unreadable; the previous save (.bak) was used.
  recoveredFromBackup,

  /// Some songs couldn't be read; the original file was kept.
  skippedSongs,

  /// Nothing could be read; the file was kept, cleanup is paused.
  unreadable,

  /// A newer app version wrote the library: shown, never overwritten.
  newerSchema,
}

class LoopStorage {
  // Documents path cache so vocal basenames can be resolved synchronously from
  // widgets/painters. Filled by [ensureDirs] (called at bootstrap + editor open).
  static String? _docsPath;

  /// Test hook: when set, this directory replaces the platform Documents dir
  /// (path_provider needs a platform channel, which unit tests don't have).
  @visibleForTesting
  static Directory? rootOverride;

  /// Shared Documents root for songs, vocals and rendered exports.
  static Future<Directory> documentsDirectory() async =>
      rootOverride ?? await getApplicationDocumentsDirectory();

  static Future<Directory> _folder() async {
    final dir = await documentsDirectory();
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
    if (nameOrPath.contains('/') || nameOrPath.contains('\\')) {
      return nameOrPath;
    }
    final docs = _docsPath;
    if (docs == null) {
      return nameOrPath; // cache not warm — caller's IO will fail gracefully
    }
    return '$docs/looptap/vocals/$nameOrPath';
  }

  static Future<File> _file() async =>
      File('${(await _folder()).path}/songs.json');
  static Future<File> _tmpFile() async =>
      File('${(await _folder()).path}/songs.json.tmp');
  static Future<File> _bakFile() async =>
      File('${(await _folder()).path}/songs.json.bak');
  static Future<File> _metaFile() async =>
      File('${(await _folder()).path}/meta.json');
  static Future<File> _userFile() async =>
      File('${(await _folder()).path}/user.json');

  // True when songs.json EXISTED but couldn't be read/parsed (and no backup
  // rescued it) — the song list is then silently empty and neither seeding nor
  // [sweepVocals] may run off it. A missing file is a legitimately empty library.
  static bool _loadFailed = false;
  static bool get loadFailed => _loadFailed;

  // Songs dropped by the lenient decoder on the last load. Their takes are
  // still on disk and still theirs — sweeping would delete them.
  static int _skippedOnLoad = 0;
  static int get skippedOnLoad => _skippedOnLoad;
  static bool _hasPreservedCorruption = false;

  static LoadIssue _lastIssue = LoadIssue.none;
  static LoadIssue get lastIssue => _lastIssue;

  /// The folder holding songs.json, vocals/ and exports/ (shown to the user).
  static Future<String> libraryPath() async => (await _folder()).path;

  static Future<List<Song>> load() async {
    _loadFailed = false;
    _skippedOnLoad = 0;
    _lastIssue = LoadIssue.none;
    final songs = await _load();
    if (_loadFailed && _lastIssue == LoadIssue.none) {
      _lastIssue = LoadIssue.unreadable;
    }
    return songs;
  }

  static bool _newer(String raw) {
    final v = Song.schemaVersionOf(raw);
    return v != null && v > Song.kSchemaVersion;
  }

  static Future<List<Song>> _load() async {
    File? f;
    try {
      _hasPreservedCorruption = await (await _folder()).list().any(
        (entry) =>
            entry.uri.pathSegments.last.startsWith('songs.json.corrupt-'),
      );
      f = await _file();
      final bak = await _bakFile();
      if (!await f.exists()) {
        // A crash between "move old → .bak" and "move tmp → songs.json" leaves
        // only the backup — that IS the library, not an empty one.
        if (await bak.exists()) {
          debugPrint('[looptap] songs.json missing, restoring from .bak');
          final r = await _decodeFile(bak);
          if (r != null) {
            _lastIssue = _newer(await bak.readAsString())
                ? LoadIssue.newerSchema
                : LoadIssue.recoveredFromBackup;
            return r;
          }
          _loadFailed = true;
        }
        _loadFailed = _loadFailed || _hasPreservedCorruption;
        return [];
      }
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) throw const FormatException('Empty songs file');
      final r = Song.decodeListLenient(raw);
      _skippedOnLoad = r.skipped;
      if (r.skipped > 0) {
        debugPrint('[looptap] load: skipped ${r.skipped} unreadable song(s)');
        // keep the original around — the skipped entries may be recoverable.
        await _preserveCorrupt(f);
        _lastIssue = LoadIssue.skippedSongs;
      }
      if (_newer(raw)) _lastIssue = LoadIssue.newerSchema;
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
          _lastIssue = _newer(await bak.readAsString())
              ? LoadIssue.newerSchema
              : LoadIssue.recoveredFromBackup;
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
      _hasPreservedCorruption = true;
      debugPrint(
        '[looptap] preserved unreadable songs file as ${dest.split('/').last}',
      );
    } catch (e) {
      debugPrint('[looptap] could not preserve corrupt songs file: $e');
    }
  }

  /// Atomic save: write the whole payload to a temp file, then swap it in.
  /// The previous songs.json survives as songs.json.bak.
  static Future<void> _saveQueue = Future<void>.value();

  static Future<void> save(List<Song> songs) {
    // Snapshot before waiting: callers may keep editing while an earlier save
    // is in flight. Only one writer may use songs.json.tmp at a time.
    final payload = Song.encodeList(songs);
    final result = _saveQueue.then((_) => _savePayload(payload));
    _saveQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static Future<void> _savePayload(String payload) async {
    try {
      final f = await _file();
      final tmp = await _tmpFile();
      final bak = await _bakFile();
      // A newer app build wrote this library: overwriting it would drop the
      // fields this build doesn't know (e.g. after a downgrade). Fail instead.
      // Both files count (storage audit 2026-10-30 S2): with songs.json gone,
      // a newer-schema .bak is the library and a save would rotate it away.
      for (final existing in [f, bak]) {
        if (!await existing.exists()) continue;
        final onDisk = Song.schemaVersionOf(await existing.readAsString());
        if (onDisk != null && onDisk > Song.kSchemaVersion) {
          throw NewerSongsSchemaException(onDisk);
        }
      }
      await tmp.writeAsString(payload, flush: true);
      if (await f.exists()) {
        if (await bak.exists()) await bak.delete();
        await f.rename(bak.path);
      }
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('[looptap] save failed: $e');
      rethrow; // Do not report success or allow cleanup of unsaved changes.
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
  static Future<String?> copyVocal(
    String srcPath,
    String songId,
    String sectionId,
  ) async {
    try {
      final dir = (await _folder()).path;
      final vocals = Directory('$dir/vocals');
      if (!await vocals.exists()) await vocals.create(recursive: true);
      final ext =
          srcPath.contains('.')
              ? srcPath.substring(srcPath.lastIndexOf('.'))
              : '.wav';
      final name =
          '${songId}_${sectionId}_${DateTime.now().millisecondsSinceEpoch}$ext';
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
    List<int> bytes,
    String songId,
    String sectionId, {
    String suffix = '',
  }) async {
    try {
      final dir = (await _folder()).path;
      final vocals = Directory('$dir/vocals');
      if (!await vocals.exists()) await vocals.create(recursive: true);
      final name =
          '${songId}_${sectionId}_${DateTime.now().millisecondsSinceEpoch}$suffix.wav';
      await File('${vocals.path}/$name').writeAsBytes(bytes);
      return name;
    } catch (e) {
      debugPrint('[looptap] saveVocalBytes failed: $e');
      return null;
    }
  }

  /// The editor's live-preview section bounces (`_mix_<song>_<section>_<rev>.wav`)
  /// are rebuilt on demand and never stored in a song, so they are always safe
  /// to delete. User takes are named `<song>_<section>_<ts>…` (never `_mix_`).
  static bool isRegenerableMix(String name) =>
      name.startsWith('_mix_') && name.endsWith('.wav');

  /// Every audio file name [song] references: section takes (current /
  /// original), clip lanes (path / original / FX source) and the song-level
  /// take. Basenames only, as stored. Shared by the sweep and project backups.
  static Set<String> audioNamesOf(Song song) {
    final names = <String>{};
    void add(String? p) {
      if (p == null || p.isEmpty) return;
      names.add(p.split('/').last.split('\\').last);
    }

    add(song.songVocalPath);
    for (final sec in song.sections) {
      for (final t in sec.tracks.values) {
        add(t.vocalPath);
        add(t.vocalOrigPath);
        for (final c in t.clips ?? const <VocalClip>[]) {
          add(c.path);
          add(c.origPath);
          add(c.fxSourcePath);
        }
      }
    }
    return names;
  }

  /// Delete vocal files no song references anymore (re-record leftovers,
  /// cleared tracks, deleted sections). Safe to call once the editor's undo
  /// stack is gone — i.e. on leaving the edit screen. Takes the backup
  /// songs.json.bak still references are kept too (storage audit 2026-10-30
  /// S1: restoring the .bak must bring its audio back); a .bak this build
  /// can't fully read, or that a newer build wrote, keeps every user take.
  static Future<void> sweepVocals(List<Song> songs) async {
    // a failed load leaves [songs] silently empty — sweeping then would
    // mass-delete takes that are still referenced by the unreadable file.
    // Likewise a partial load: the skipped songs' takes are still theirs, and
    // so are those a preserved songs.json.corrupt-* may reference. In those
    // cases only regenerable `_mix_*` editor bounces (never persisted in any
    // song) are swept, so they can't pile up forever; user takes are kept.
    var mixesOnly =
        _loadFailed || _skippedOnLoad > 0 || _hasPreservedCorruption;
    try {
      final vocals = Directory('${(await _folder()).path}/vocals');
      if (!await vocals.exists()) return;
      // belt and braces: an empty library legitimately has no takes to keep,
      // but if the list is empty while takes exist on disk, prefer keeping
      // them over an irreversible mass delete.
      if (!mixesOnly &&
          songs.isEmpty &&
          await vocals.list().any(
            (f) => !isRegenerableMix(f.uri.pathSegments.last),
          )) {
        debugPrint(
          '[looptap] sweepVocals: empty song list with takes on disk, '
          'sweeping bounces only',
        );
        mixesOnly = true;
      }
      final keep = <Song>[...songs];
      final bak = await _bakFile();
      if (!mixesOnly && await bak.exists()) {
        try {
          final raw = await bak.readAsString();
          final v = Song.schemaVersionOf(raw);
          final r = Song.decodeListLenient(raw);
          if ((v != null && v > Song.kSchemaVersion) || r.skipped > 0) {
            mixesOnly = true; // can't tell everything it references
          } else {
            keep.addAll(r.songs);
          }
        } catch (_) {
          mixesOnly = true;
        }
      }
      final referenced = <String>{};
      for (final song in keep) {
        for (final base in audioNamesOf(song)) {
          referenced.add(base);
          // keep the legacy-conversion cache wav_export writes next to legacy
          // takes (see _loadVocalBytes: '<take>.cnv.wav') — the song-level
          // take's too
          referenced.add('$base.cnv.wav');
        }
      }
      await for (final f in vocals.list()) {
        final name = f.uri.pathSegments.last;
        if (mixesOnly && !isRegenerableMix(name)) continue;
        if (f is File && !referenced.contains(name)) {
          try {
            await f.delete();
          } catch (_) {}
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
