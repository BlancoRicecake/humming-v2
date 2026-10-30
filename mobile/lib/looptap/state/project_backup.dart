// Portable project backup (storage audit 2026-10-30): one song and every
// audio file it references, in a `.humtrack` file (a ZIP) that moves between
// phone and PC and imports as an editable song. WAV / MIDI exports are
// renders — they can't be edited back; this is the editable copy.
//
// Layout (formatVersion 1):
//   manifest.json  {format: "humtrack-project", formatVersion: 1,
//                   songSchema: Song.kSchemaVersion, app, createdAt, title,
//                   files: [{path: "audio/<name>", name, size, sha256}],
//                   missing: [<name>…]}   ← referenced but absent at backup
//   song.json      {v: <songSchema>, song: {…Song.toJson()}}
//   audio/<name>   each referenced take, byte for byte (stored, no deflate)
//
// Import accepts only that layout: no other entries, no directories but
// `audio/`, no links, no `..` / absolute / backslash / drive paths, bounded
// sizes and counts; a newer format or song schema is refused (never
// downgraded); every listed file must be present with the same size and
// SHA-256, and every take the song references must be listed (or recorded as
// already missing). The song always lands as a NEW song with new audio file
// names — nothing existing is overwritten — and a failure removes whatever
// the import wrote.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart'
    show Archive, ArchiveFile, ZipEncoder, getCrc32;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/loop_models.dart';
import '../music/song_util.dart';
import 'loop_storage.dart';
import 'loop_store.dart';

const kBackupFormat = 'humtrack-project';
const kBackupFormatVersion = 1;
const kBackupExtension = 'humtrack';

/// Limits for an imported file (a phone-made backup is far below them).
const kBackupMaxBytes = 1024 * 1024 * 1024; // the .humtrack itself
const kBackupMaxEntryBytes = 512 * 1024 * 1024; // one take
const kBackupMaxJsonBytes = 32 * 1024 * 1024; // manifest / song
const kBackupMaxFiles = 2000;

enum BackupProblem {
  /// Not a ZIP, or not a HumTrack project backup.
  notBackup,

  /// Made by a newer HumTrack (format or song schema): update the app.
  newerVersion,

  /// An entry outside the allowed layout (path escape, link, extra file).
  unsafeEntry,

  /// Larger than the limits above.
  tooLarge,

  /// A take the song needs isn't in the file.
  missingAudio,

  /// A file doesn't match its recorded size / checksum, or the song can't be
  /// read.
  damaged,
}

class ProjectBackupException implements Exception {
  const ProjectBackupException(this.problem, [this.detail]);
  final BackupProblem problem;
  final String? detail;
  @override
  String toString() =>
      'ProjectBackupException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// A validated backup's content.
class ProjectBackupContents {
  const ProjectBackupContents({
    required this.songJson,
    required this.audio,
    required this.missing,
  });

  /// The song as stored (Song.toJson shape).
  final Map<String, dynamic> songJson;

  /// Take name → bytes (checked against the manifest).
  final Map<String, Uint8List> audio;

  /// Takes the song referenced that were already missing at backup time.
  final Set<String> missing;
}

/// A take name as the app stores it: a plain file name, nothing that can
/// walk out of the vocals folder or name a device.
bool isSafeAudioName(String name) {
  if (name.isEmpty || name.length > 200) return false;
  if (name == '.' || name == '..' || name.startsWith('.')) return false;
  if (RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]').hasMatch(name)) return false;
  if (name.endsWith(' ') || name.endsWith('.')) return false;
  return exportFileName(name) == name; // also refuses CON, NUL, COM1…
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// Pure: the `.humtrack` bytes for [songJson] and its [audio].
@visibleForTesting
Uint8List encodeProjectBackup({
  required Map<String, dynamic> songJson,
  required Map<String, Uint8List> audio,
  Set<String> missing = const {},
  bool audioIncluded = true,
  DateTime? now,
}) {
  final names = audio.keys.toList()..sort();
  final manifest = {
    'format': kBackupFormat,
    'formatVersion': kBackupFormatVersion,
    'songSchema': Song.kSchemaVersion,
    'app': 'HumTrack',
    'createdAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'title': songJson['title'],
    'files': [
      for (final n in names)
        {
          'path': 'audio/$n',
          'name': n,
          'size': audio[n]!.length,
          'sha256': _sha(audio[n]!),
        },
    ],
    'missing': (missing.toList()..sort()),
    // false: recordings left out on purpose (a notes-only cloud copy); the
    // song's takes are then all listed in `missing` and restore silent
    'audioIncluded': audioIncluded,
  };
  // v1 is a STORED zip (no compression) throughout: takes are already PCM or
  // compressed audio, and an importer then never inflates anything.
  ArchiveFile stored(String name, List<int> data) =>
      ArchiveFile.noCompress(name, data.length, data);
  final archive =
      Archive()
        ..addFile(
          stored(
            'manifest.json',
            utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
          ),
        )
        ..addFile(
          stored(
            'song.json',
            utf8.encode(
              jsonEncode({'v': Song.kSchemaVersion, 'song': songJson}),
            ),
          ),
        );
  for (final n in names) {
    archive.addFile(stored('audio/$n', audio[n]!));
  }
  return ZipEncoder().encodeBytes(archive);
}

const kBackupMaxTotalBytes = kBackupMaxBytes; // all entries together

/// One stored entry of a v1 backup.
typedef _ZipEntry = ({String name, Uint8List data});

int _u16(Uint8List b, int o) => b[o] | b[o + 1] << 8;
int _u32(Uint8List b, int o) =>
    b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;

/// The entries of a STORED zip, read from its central directory and checked
/// against the local headers: one disk, no zip64, no encryption, no links,
/// method 0 only (size == compressed size), unique names (also ignoring
/// case — Windows/macOS folders), entries that don't overlap and fit the
/// file, bounded count and total size, and each CRC-32 recomputed.
List<_ZipEntry> _readStoredZip(Uint8List b) {
  Never bad([String? why]) =>
      throw ProjectBackupException(BackupProblem.notBackup, why);
  Never unsafe(String why) =>
      throw ProjectBackupException(BackupProblem.unsafeEntry, why);
  if (b.length < 22) bad('short');
  // end of central directory: the last signature within the comment window
  var eocd = -1;
  for (var i = b.length - 22; i >= 0 && i >= b.length - 22 - 0xFFFF; i--) {
    if (_u32(b, i) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) bad('no zip directory');
  final disk = _u16(b, eocd + 4), cdDisk = _u16(b, eocd + 6);
  final countHere = _u16(b, eocd + 8), count = _u16(b, eocd + 10);
  final cdSize = _u32(b, eocd + 12), cdOffset = _u32(b, eocd + 16);
  if (disk != 0 || cdDisk != 0 || countHere != count) bad('multi-disk');
  if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
    bad('zip64');
  }
  if (count > kBackupMaxFiles + 3) {
    throw const ProjectBackupException(BackupProblem.tooLarge, 'entries');
  }
  if (cdOffset + cdSize > eocd) bad('directory bounds');
  final out = <_ZipEntry>[];
  final seen = <String>{};
  final ranges = <(int, int)>[];
  var total = 0;
  var p = cdOffset;
  for (var i = 0; i < count; i++) {
    if (p + 46 > cdOffset + cdSize || _u32(b, p) != 0x02014b50) bad('entry');
    final flags = _u16(b, p + 8), method = _u16(b, p + 10);
    final crc = _u32(b, p + 16);
    final csize = _u32(b, p + 20), usize = _u32(b, p + 24);
    final nlen = _u16(b, p + 28), xlen = _u16(b, p + 30), clen = _u16(b, p + 32);
    final madeBy = _u16(b, p + 4) >> 8, attrs = _u32(b, p + 38);
    final local = _u32(b, p + 42);
    if (p + 46 + nlen > cdOffset + cdSize) bad('entry name');
    final String name;
    try {
      name = utf8.decode(b.sublist(p + 46, p + 46 + nlen));
    } catch (_) {
      unsafe('name encoding');
    }
    p += 46 + nlen + xlen + clen;
    if (flags & 0x1 != 0) unsafe('encrypted $name');
    // a unix symlink (made by unix, mode S_IFLNK)
    if (madeBy == 3 && (attrs >> 16) & 0xF000 == 0xA000) unsafe('link $name');
    if (!seen.add(name.toLowerCase())) unsafe('duplicate $name');
    if (name.endsWith('/')) {
      if (name != 'audio/' || usize != 0) unsafe(name);
      continue;
    }
    if (method != 0 || csize != usize) unsafe('compressed $name');
    total += usize;
    if (total > kBackupMaxTotalBytes) {
      throw const ProjectBackupException(BackupProblem.tooLarge, 'total');
    }
    if (local + 30 > cdOffset || _u32(b, local) != 0x04034b50) {
      bad('local header $name');
    }
    final lnlen = _u16(b, local + 26), lxlen = _u16(b, local + 28);
    final start = local + 30 + lnlen + lxlen;
    final end = start + usize;
    if (end > cdOffset) bad('data bounds $name');
    final localName = b.sublist(local + 30, local + 30 + lnlen);
    if (utf8.decode(localName, allowMalformed: true) != name) {
      unsafe('header mismatch $name');
    }
    ranges.add((local, end));
    final data = Uint8List.sublistView(b, start, end);
    if (getCrc32(data) != crc) {
      throw ProjectBackupException(BackupProblem.damaged, 'crc $name');
    }
    out.add((name: name, data: data));
  }
  ranges.sort((x, y) => x.$1.compareTo(y.$1));
  for (var i = 1; i < ranges.length; i++) {
    if (ranges[i].$1 < ranges[i - 1].$2) unsafe('overlapping entries');
  }
  return out;
}

/// Pure: read and fully validate a `.humtrack` file (see the file comment).
/// Throws [ProjectBackupException].
ProjectBackupContents decodeProjectBackup(Uint8List bytes) {
  if (bytes.length > kBackupMaxBytes) {
    throw const ProjectBackupException(BackupProblem.tooLarge);
  }
  // Read the ZIP's own central directory (not a library's merged view), so
  // duplicates, links, paths, methods and sizes are judged BEFORE any data is
  // taken out; v1 entries are stored (no compression), so nothing is
  // inflated and an entry's output is exactly its bytes in the file.
  final raw = _readStoredZip(bytes);
  final entries = <String, Uint8List>{};
  for (final e in raw) {
    final name = e.name;
    if (name == 'audio/') continue; // the folder entry some tools add
    final ok =
        name == 'manifest.json' ||
        name == 'song.json' ||
        (name.startsWith('audio/') && isSafeAudioName(name.substring(6)));
    if (!ok) throw ProjectBackupException(BackupProblem.unsafeEntry, name);
    final limit =
        name.startsWith('audio/') ? kBackupMaxEntryBytes : kBackupMaxJsonBytes;
    if (e.data.length > limit) {
      throw ProjectBackupException(BackupProblem.tooLarge, name);
    }
    entries[name] = e.data;
  }
  Uint8List read(String name, int limit) {
    final data = entries[name];
    if (data == null) {
      throw ProjectBackupException(BackupProblem.notBackup, name);
    }
    return data;
  }

  Map<String, dynamic> json(String name) {
    try {
      final v = jsonDecode(utf8.decode(read(name, kBackupMaxJsonBytes)));
      if (v is Map<String, dynamic>) return v;
    } on ProjectBackupException {
      rethrow;
    } catch (_) {}
    throw ProjectBackupException(
      name == 'manifest.json' ? BackupProblem.notBackup : BackupProblem.damaged,
      name,
    );
  }

  final manifest = json('manifest.json');
  if (manifest['format'] != kBackupFormat) {
    throw const ProjectBackupException(BackupProblem.notBackup, 'format');
  }
  final fv = manifest['formatVersion'];
  final schema = manifest['songSchema'];
  if (fv is! int || schema is! int) {
    throw const ProjectBackupException(BackupProblem.notBackup, 'version');
  }
  if (fv > kBackupFormatVersion || schema > Song.kSchemaVersion) {
    throw ProjectBackupException(BackupProblem.newerVersion, '$fv/$schema');
  }
  final song = json('song.json');
  final v = song['v'];
  if (v is! int || v > Song.kSchemaVersion) {
    throw ProjectBackupException(BackupProblem.newerVersion, 'song v$v');
  }
  final songJson = song['song'];
  if (songJson is! Map<String, dynamic>) {
    throw const ProjectBackupException(BackupProblem.damaged, 'song');
  }
  final Song parsed;
  try {
    parsed = Song.fromJson(songJson);
  } catch (e) {
    throw ProjectBackupException(BackupProblem.damaged, 'song: $e');
  }

  final files = manifest['files'];
  final missingList = manifest['missing'] ?? const [];
  if (files is! List || missingList is! List) {
    throw const ProjectBackupException(BackupProblem.notBackup, 'files');
  }
  final audio = <String, Uint8List>{};
  for (final e in files) {
    if (e is! Map) {
      throw const ProjectBackupException(BackupProblem.notBackup, 'files');
    }
    final name = e['name'], path = e['path'], size = e['size'], hash = e['sha256'];
    if (name is! String ||
        path != 'audio/$name' ||
        !isSafeAudioName(name) ||
        size is! int ||
        hash is! String ||
        audio.containsKey(name)) {
      throw ProjectBackupException(BackupProblem.unsafeEntry, '$path');
    }
    if (!entries.containsKey(path)) {
      throw ProjectBackupException(BackupProblem.missingAudio, name);
    }
    final data = read(path as String, kBackupMaxEntryBytes);
    if (data.length != size || _sha(data) != hash) {
      throw ProjectBackupException(BackupProblem.damaged, name);
    }
    audio[name] = data;
  }
  // nothing in audio/ that the manifest doesn't vouch for
  for (final name in entries.keys) {
    if (name.startsWith('audio/') && !audio.containsKey(name.substring(6))) {
      throw ProjectBackupException(BackupProblem.unsafeEntry, name);
    }
  }
  final missing = <String>{
    for (final m in missingList)
      if (m is String && isSafeAudioName(m)) m,
  };
  for (final name in LoopStorage.audioNamesOf(parsed)) {
    if (!audio.containsKey(name) && !missing.contains(name)) {
      throw ProjectBackupException(BackupProblem.missingAudio, name);
    }
  }
  return ProjectBackupContents(
    songJson: songJson,
    audio: audio,
    missing: missing,
  );
}

/// Write a `.humtrack` for [song] into the exports folder (the in-app "files"
/// list, from where it is saved to the device or shared). [missing] counts
/// takes the song references that were already gone (recorded in the file).
Future<({File file, int missing})> createProjectBackup(Song song) async {
  final built = await buildProjectBackup(song);
  final bytes = built.bytes;
  final folder = await exportsFolder();
  final file = await uniqueExportFile(
    folder,
    exportFileName(song.title, fallback: song.id),
    kBackupExtension,
  );
  await writeExportFile(file, bytes);
  return (file: file, missing: built.missing);
}

/// The `.humtrack` bytes of [song]. With [includeAudio] false the takes stay
/// on this device: none is read or packed, all are listed as missing and the
/// manifest says `audioIncluded: false` (cloud "notes only" copies).
/// [takes] = recordings the song references; [missing] = those not packed.
Future<({Uint8List bytes, int takes, int missing})> buildProjectBackup(
  Song song, {
  bool includeAudio = true,
}) async {
  final names = LoopStorage.audioNamesOf(song);
  final audio = <String, Uint8List>{};
  final missing = <String>{};
  for (final name in names) {
    if (!includeAudio || !isSafeAudioName(name)) {
      missing.add(name); // left out / never written into a backup as a path
      continue;
    }
    final f = File(LoopStorage.resolveVocal(name));
    if (await f.exists()) {
      audio[name] = await f.readAsBytes();
    } else {
      missing.add(name);
    }
  }
  final songJson =
      (jsonDecode(jsonEncode(song.toJson())) as Map).cast<String, dynamic>();
  final bytes = await compute(
    _encode,
    _EncodeArgs(songJson, audio, missing, includeAudio),
  );
  return (bytes: bytes, takes: names.length, missing: missing.length);
}

Uint8List _encode(_EncodeArgs a) => encodeProjectBackup(
  songJson: a.song,
  audio: a.audio,
  missing: a.missing,
  audioIncluded: a.audioIncluded,
);

class _EncodeArgs {
  const _EncodeArgs(this.song, this.audio, this.missing, this.audioIncluded);
  final Map<String, dynamic> song;
  final Map<String, Uint8List> audio;
  final Set<String> missing;
  final bool audioIncluded;
}

/// Validate [bytes] and add the song to [store] as a new song (new id, new
/// take file names). Throws [ProjectBackupException] (nothing written) or the
/// save error (whatever was written is removed again).
Future<({Song song, int missing})> importProjectBackup(
  LoopStore store,
  Uint8List bytes,
) async {
  final contents = await compute(decodeProjectBackup, bytes);
  final stamp = _nextImportStamp(store);
  final id = 'lt$stamp';
  await LoopStorage.ensureDirs();
  final vocals = Directory(
    '${(await LoopStorage.documentsDirectory()).path}/looptap/vocals',
  );
  // Every take gets a NEW name no file here has (case ignored: Windows and
  // macOS folders), so an import never reuses — or plays — another song's
  // recording. That includes takes that were already missing on the source
  // device (B1): they point to a fresh name with no file behind it, so they
  // stay silent instead of picking up a same-named take here.
  final taken = <String>{
    if (await vocals.exists())
      for (final f in vocals.listSync()) f.uri.pathSegments.last.toLowerCase(),
  };
  final rename = <String, String>{};
  for (final name in [...contents.audio.keys, ...contents.missing]) {
    rename[name] = _importName(stamp, name, taken);
  }
  final json = _rewriteAudio(contents.songJson, rename) as Map<String, dynamic>;
  final song =
      Song.fromJson(json)
        ..id = id
        ..updatedAt = DateTime.now();
  final written = <File>[];
  await store.addWithFiles(
    song,
    write: () async {
      await vocals.create(recursive: true);
      for (final e in rename.entries) {
        if (!contents.audio.containsKey(e.key)) continue; // missing take
        final f = File('${vocals.path}/${e.value}');
        await f.create(exclusive: true); // never replace an existing take
        written.add(f);
        await f.writeAsBytes(contents.audio[e.key]!, flush: true);
      }
    },
    undo: () async {
      for (final f in written) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    },
  );
  return (song: song, missing: contents.missing.length);
}

int _lastImportStamp = 0;

/// A millisecond stamp for the import's song id and take names that is
/// strictly increasing in this process and not any library song's id, so two
/// imports in the same millisecond can't collide (B2).
int _nextImportStamp(LoopStore store) {
  var stamp = DateTime.now().millisecondsSinceEpoch;
  if (stamp <= _lastImportStamp) stamp = _lastImportStamp + 1;
  final ids = {for (final s in store.songs) s.id.toLowerCase()};
  while (ids.contains('lt$stamp')) {
    stamp++;
  }
  return _lastImportStamp = stamp;
}

/// `imp<stamp>[-n]_<stem>.<ext>`, at most 200 characters: the unique prefix
/// and the extension are always kept and the original stem is shortened, so
/// raising `n` always yields a new candidate (B2). [taken] (lower case) is
/// updated with the result.
String _importName(int stamp, String name, Set<String> taken) {
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 12 ? name.substring(dot) : '';
  final stem = ext.isEmpty ? name : name.substring(0, dot);
  for (var n = 0; ; n++) {
    final prefix = 'imp$stamp${n == 0 ? '' : '-$n'}_';
    final room = 200 - prefix.length - ext.length;
    var short = stem.length > room ? stem.substring(0, room) : stem;
    // a cut must not leave a trailing dot / space (not a valid name)
    short = short.replaceAll(RegExp(r'[. ]+$'), '');
    final candidate = '$prefix${short.isEmpty ? 'take' : short}$ext';
    if (taken.add(candidate.toLowerCase())) return candidate;
  }
}

const _audioKeys = {
  'songVocalPath',
  'vocalPath',
  'vocalOrigPath',
  'path',
  'origPath',
  'fxSourcePath',
};

/// [node] with every take reference (by its stored basename) renamed.
Object? _rewriteAudio(Object? node, Map<String, String> rename) {
  if (node is Map) {
    return {
      for (final e in node.entries)
        e.key as String:
            _audioKeys.contains(e.key) && e.value is String
                ? (rename[(e.value as String).split('/').last.split('\\').last] ??
                    e.value)
                : _rewriteAudio(e.value, rename),
    };
  }
  if (node is List) return [for (final v in node) _rewriteAudio(v, rename)];
  return node;
}
