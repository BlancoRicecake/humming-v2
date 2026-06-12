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

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/engine_api.dart';

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

  List<SoundfontEntry> get all => _bySlot.values.toList(growable: false);
  SoundfontEntry? bySlot(int slot) => _bySlot[slot];

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/looptap/soundfonts');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  File _fileFor(SoundfontEntry e) => File('${_dir!.path}/${e.id}.sf2');

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
  Future<void> warm() async {
    if (_manifestLoaded) return;
    await _folder();
    try {
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
    await _folder();
    try {
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
  Future<String?> ensureDownloaded(int slot) async {
    final e = _bySlot[slot];
    if (e == null) return null;
    await _folder();
    final f = _fileFor(e);
    if (await f.exists() && await f.length() == e.bytes) return f.path;
    try {
      final bytes = await EngineApi().downloadSoundfont(e.id);
      if (e.bytes > 0 && bytes.length != e.bytes) {
        debugPrint('[soundfont] ${e.id} size mismatch ${bytes.length}/${e.bytes}');
        return null;
      }
      await f.writeAsBytes(bytes, flush: true);
      return f.path;
    } catch (err) {
      debugPrint('[soundfont] download ${e.id} failed: $err');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
      return null;
    }
  }
}
