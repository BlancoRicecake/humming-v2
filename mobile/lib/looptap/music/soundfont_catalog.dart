// Runtime SoundFont catalog — instruments downloaded on demand from the
// backend (GET /soundfonts) instead of bundled at build time. A "sound" is
// still just an int `program`: catalog entries use a unique [slot] >= 1000
// (GM 0-127, 808=128, hip-hop=200 are reserved), stored on the song like any
// program. synth.dart / wav_export.dart / midi_export.dart resolve slot ->
// local file via [SoundfontCatalog]; an unknown slot falls back to the
// track's default instrument.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/engine_api.dart';
import '../../audio/backup_exclusion.dart';

/// Catalog program slots start here — must match backend MIN_SLOT.
const int kSoundfontSlotBase = 1000;

bool isDynamicSlot(int program) => program >= kSoundfontSlotBase;

/// One downloadable instrument (mirror of the backend manifest row).
class SoundfontEntry {
  const SoundfontEntry({
    required this.id,
    required this.slot,
    required this.label,
    required this.role, // 'melody' | 'bass' | 'drums'
    required this.category,
    required this.bytes,
    required this.sha256,
    required this.sfBank,
    required this.sfProgram,
    required this.midiFallback,
  });

  final String id;
  final int slot;
  final String label;
  final String role;
  final String category;
  final int bytes;
  final String sha256;
  final int sfBank;
  final int sfProgram;
  final int midiFallback;

  static SoundfontEntry fromJson(Map<String, dynamic> j) => SoundfontEntry(
        id: j['id'] as String,
        slot: (j['slot'] as num).toInt(),
        label: (j['label'] ?? '') as String,
        role: (j['role'] ?? 'melody') as String,
        category: (j['category'] ?? '') as String,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        sha256: (j['sha256'] ?? '') as String,
        sfBank: (j['sf_bank'] as num?)?.toInt() ?? 0,
        sfProgram: (j['sf_program'] as num?)?.toInt() ?? 0,
        midiFallback: (j['midi_fallback'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toCache() => {
        'id': id,
        'slot': slot,
        'label': label,
        'role': role,
        'category': category,
        'bytes': bytes,
        'sha256': sha256,
        'sf_bank': sfBank,
        'sf_program': sfProgram,
        'midi_fallback': midiFallback,
      };
}

/// Catalog manifest + on-disk SF2 cache. Singleton: synth/export/picker all
/// read the same downloaded-file registry.
class SoundfontCatalog {
  SoundfontCatalog._();
  static final SoundfontCatalog instance = SoundfontCatalog._();

  final Map<int, SoundfontEntry> _bySlot = {};
  Directory? _dir;
  bool _manifestLoaded = false;

  /// In-progress downloads as slot -> 0..1 (entries removed on completion).
  /// The instrument picker watches this to show a progress ring.
  final ValueNotifier<Map<int, double>> downloadProgress =
      ValueNotifier<Map<int, double>>(const {});

  /// De-dupe concurrent downloads of the same slot (re-opening the picker and
  /// tapping again reuses the in-flight future instead of downloading twice).
  final Map<int, Future<String?>> _inFlight = {};

  void _setProgress(int slot, double? v) {
    final m = Map<int, double>.from(downloadProgress.value);
    if (v == null) {
      m.remove(slot);
    } else {
      m[slot] = v;
    }
    downloadProgress.value = m;
  }

  List<SoundfontEntry> get all => _bySlot.values.toList(growable: false);
  SoundfontEntry? bySlot(int slot) => _bySlot[slot];

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/looptap/soundfonts');
    if (!await d.exists()) await d.create(recursive: true);
    // C18: catalog SF2s are 200-400MB and re-downloadable — keep them out of
    // the user's iCloud backup. In place (no relocation, so already-downloaded
    // fonts keep working); the flag on the directory covers its contents.
    // Never throws, so it can't block bootstrap (A17).
    await excludeFromBackup(d.path);
    return _dir = d;
  }

  /// Test hook: point the cache at a directory without path_provider.
  @visibleForTesting
  void debugSetDirectory(Directory d) => _dir = d;

  File _fileFor(SoundfontEntry e) => File('${_dir!.path}/${e.id}.sf2');

  /// Lower-case hex sha256 of [f], streamed (SF2s are tens of MB — never
  /// read whole into memory just to hash).
  static Future<String> fileSha256(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();

  /// Remove a downloaded soundfont (and any stale `.part`) by manifest id.
  /// Returns true when a file was actually deleted. The manifest entry stays —
  /// the slot simply reads as not-downloaded again (synth falls back to the
  /// track's default instrument until re-downloaded). A synth that already
  /// loaded the file keeps its in-memory copy until the app restarts.
  Future<bool> delete(String id) async {
    try {
      final dir = await _folder();
      var removed = false;
      for (final name in ['$id.sf2', '$id.sf2.part']) {
        final f = File('${dir.path}/$name');
        if (await f.exists()) {
          await f.delete();
          removed = true;
        }
      }
      return removed;
    } catch (e) {
      debugPrint('[soundfont] delete $id failed: $e');
      return false;
    }
  }

  /// Absolute path of a downloaded slot's SF2, or null if not present. Sync —
  /// callers (export job builder) must have called [warm]/[ensureDownloaded]
  /// first; the registry is in memory.
  String? localPath(int slot) {
    final e = _bySlot[slot];
    if (e == null || _dir == null) return null;
    final f = _fileFor(e);
    return f.existsSync() ? f.path : null;
  }

  bool isDownloaded(int slot) => localPath(slot) != null;

  /// GM program to substitute in .mid export for a dynamic slot (a Standard
  /// MIDI File can't carry a custom patch). 0 (Grand Piano) when unknown.
  int midiFallback(int slot) => _bySlot[slot]?.midiFallback ?? 0;

  /// Load the cached manifest (instant) so the picker + slot resolution work
  /// offline; call [refresh] to pull the latest from the backend.
  ///
  /// Never throws: this runs inside LoopStore.bootstrap, and a path_provider /
  /// filesystem failure here must not block app start (audit A17) — the
  /// catalog simply stays empty until [refresh] succeeds.
  Future<void> warm() async {
    if (_manifestLoaded) return;
    try {
      await _folder();
      final f = File('${_dir!.path}/catalog.json');
      if (await f.exists()) {
        final list = (jsonDecode(await f.readAsString()) as List)
            .map((e) => SoundfontEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        _replace(list);
      }
    } catch (e) {
      debugPrint('[soundfont] warm failed: $e');
    }
    _manifestLoaded = true;
  }

  /// Fetch the latest manifest from the backend; caches it for offline use.
  /// Returns false on network error (keeps the warmed cache).
  Future<bool> refresh() async {
    try {
      await _folder(); // inside the try: bootstrap fires this unawaited
      final list = await EngineApi().soundfontCatalogMapped(SoundfontEntry.fromJson);
      _replace(list);
      final f = File('${_dir!.path}/catalog.json');
      await f.writeAsString(jsonEncode(list.map((e) => e.toCache()).toList()));
      _manifestLoaded = true;
      return true;
    } catch (e) {
      debugPrint('[soundfont] refresh failed: $e');
      return false;
    }
  }

  void _replace(List<SoundfontEntry> list) {
    _bySlot
      ..clear()
      ..addEntries(list.map((e) => MapEntry(e.slot, e)));
  }

  /// Ensure the slot's SF2 is downloaded + verified; returns its local path or
  /// null (offline / unknown slot / verification failed). Idempotent: a present
  /// correctly-sized file short-circuits.
  Future<String?> ensureDownloaded(int slot) {
    return _inFlight.putIfAbsent(
      slot,
      () => _doDownload(slot).whenComplete(() => _inFlight.remove(slot)),
    );
  }

  Future<String?> _doDownload(int slot) async {
    final e = _bySlot[slot];
    if (e == null) return null;
    await _folder();
    final f = _fileFor(e);
    if (await f.exists() && await f.length() == e.bytes) return f.path;
    // Stream to a .part file so an interrupted download is never mistaken for a
    // complete one; only rename in once the size is verified.
    final part = File('${f.path}.part');
    _setProgress(slot, 0);
    try {
      await EngineApi().downloadSoundfontToFile(
        e.id,
        part.path,
        expectedBytes: e.bytes,
        onProgress: (recv, total) {
          final t = total > 0 ? total : e.bytes;
          if (t > 0) _setProgress(slot, (recv / t).clamp(0.0, 1.0));
        },
      );
      final len = await part.length();
      if (e.bytes > 0 && len != e.bytes) {
        debugPrint('[soundfont] ${e.id} size mismatch $len/${e.bytes}');
        if (await part.exists()) await part.delete();
        return null;
      }
      // Integrity: a right-sized but corrupt/tampered file would otherwise be
      // renamed in and fed straight to the synth (audit A16/C19). Only when
      // the manifest carries a digest; streamed so big SF2s aren't buffered.
      if (e.sha256.isNotEmpty) {
        final got = await fileSha256(part);
        if (got != e.sha256.toLowerCase()) {
          debugPrint('[soundfont] ${e.id} sha256 mismatch $got/${e.sha256}');
          if (await part.exists()) await part.delete();
          return null;
        }
      }
      if (await f.exists()) await f.delete();
      await part.rename(f.path);
      return f.path;
    } catch (err) {
      // Keep the .part file: the next attempt resumes from its length with a
      // Range request instead of re-fetching a 300MB font from zero (audit
      // A16b). It is never mistaken for a finished download — only the
      // size + sha256 verified rename below produces the real file. A
      // *corrupt* part is deleted above, before we get here.
      final partial = await part.exists() ? await part.length() : 0;
      debugPrint('[soundfont] download ${e.id} failed at $partial bytes '
          '(will resume): $err');
      return null;
    } finally {
      _setProgress(slot, null);
    }
  }
}
