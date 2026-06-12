// LoopTap persistence — single JSON file <Documents>/looptap/songs.json,
// mirroring the prototype's localStorage["looptap_songs_v1"].
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/loop_models.dart';

class LoopStorage {
  // Documents path cache so vocal basenames can be resolved synchronously from
  // widgets/painters. Filled by [ensureDirs] (called at bootstrap + editor open).
  static String? _docsPath;

  static Future<Directory> _folder() async {
    final dir = await getApplicationDocumentsDirectory();
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
  static Future<File> _userFile() async => File('${(await _folder()).path}/user.json');

  // True when songs.json EXISTED but couldn't be read/parsed — the song list
  // is then silently empty and [sweepVocals] must not run off it (it would
  // delete every take). A missing file is a legitimately empty library.
  static bool _loadFailed = false;

  static Future<List<Song>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        _loadFailed = false;
        return [];
      }
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) {
        _loadFailed = false;
        return [];
      }
      final songs = Song.decodeList(raw);
      _loadFailed = false;
      return songs;
    } catch (e) {
      debugPrint('[looptap] load failed: $e');
      _loadFailed = true;
      return [];
    }
  }

  static Future<void> save(List<Song> songs) async {
    try {
      final f = await _file();
      await f.writeAsString(Song.encodeList(songs));
    } catch (e) {
      debugPrint('[looptap] save failed: $e');
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
    if (_loadFailed) return;
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
        for (final sec in song.sections) {
          for (final t in sec.tracks.values) {
            for (final p in [t.vocalPath, t.vocalOrigPath]) {
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
