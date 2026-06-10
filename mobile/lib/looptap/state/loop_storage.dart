// LoopTap persistence — single JSON file <Documents>/looptap/songs.json,
// mirroring the prototype's localStorage["looptap_songs_v1"].
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/loop_models.dart';

class LoopStorage {
  static Future<Directory> _folder() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/looptap');
    if (!await folder.exists()) await folder.create(recursive: true);
    return folder;
  }

  static Future<File> _file() async => File('${(await _folder()).path}/songs.json');
  static Future<File> _userFile() async => File('${(await _folder()).path}/user.json');

  static Future<List<Song>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return [];
      return Song.decodeList(raw);
    } catch (e) {
      debugPrint('[looptap] load failed: $e');
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

  /// Copy a freshly-recorded vocal file into persistent storage and return the
  /// new path under Documents/looptap/vocals/ (named songId_sectionId.m4a).
  static Future<String?> copyVocal(String srcPath, String songId, String sectionId) async {
    try {
      final dir = (await _folder()).path;
      final vocals = Directory('$dir/vocals');
      if (!await vocals.exists()) await vocals.create(recursive: true);
      final ext = srcPath.contains('.') ? srcPath.substring(srcPath.lastIndexOf('.')) : '.m4a';
      final dest = '${vocals.path}/${songId}_$sectionId$ext';
      await File(srcPath).copy(dest);
      return dest;
    } catch (e) {
      debugPrint('[looptap] copyVocal failed: $e');
      return null;
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
