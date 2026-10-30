// Manual cloud backup of a song (Pro), backup contract 1 (2026-10-30).
//
// A cloud copy IS the song's `.humtrack` project backup (state/
// project_backup.dart), so restoring goes through the same validated importer
// as a backup file and always lands as a NEW local song. Recordings are
// included only when the user ticks it; otherwise a "notes only" copy is made
// (the takes stay on this device). Nothing uploads by itself: no call here
// runs on app start, sign-in or settings — only from an explicit action.
//
// Upload: POST /storage/presign (our API, account token) → PUT the bytes to
// the signed R2 URL (no token: only the signed headers) → POST /projects
// commits it. The server switches the cloud copy atomically and keeps the
// previous one on any failure; a stale device gets a conflict
// ([CloudConflict]) and decides: keep this device's / take the cloud's /
// keep both.
//
// Feature flag: HUMTRACK_CLOUD_BACKUP (dart-define, default off). A server
// without the feature (404) or without backup contract 1 stops before any
// upload. Signed URLs, tokens and song content are never logged.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/loop_models.dart';
import 'loop_storage.dart';
import 'loop_store.dart';
import 'project_backup.dart';

const kCloudBackupEnabled = bool.fromEnvironment(
  'HUMTRACK_CLOUD_BACKUP',
  defaultValue: false,
);

/// The backup contract this app speaks (server GET /storage/usage `contract`).
const kCloudContract = 1;

// ── errors ───────────────────────────────────────────────────────────────
sealed class CloudException implements Exception {
  const CloudException();
}

/// The server doesn't offer cloud backup (feature off / older deployment).
class CloudUnavailable extends CloudException {
  const CloudUnavailable();
}

/// Not signed in (or the session expired).
class CloudSignInRequired extends CloudException {
  const CloudSignInRequired();
}

/// Uploading needs Pro (reading and deleting don't).
class CloudProRequired extends CloudException {
  const CloudProRequired();
}

class CloudQuotaExceeded extends CloudException {
  const CloudQuotaExceeded(this.used, this.quota);
  final int used, quota;
}

/// The cloud copy changed since this device last saw it (another device), or
/// it was deleted, or a first upload found one already there. [upload] is the
/// already-uploaded object, so "keep this device's" commits it without
/// sending the bytes again.
class CloudConflict extends CloudException {
  const CloudConflict({required this.cloud, required this.upload});
  final CloudCopy? cloud;
  final CloudUpload upload;
}

/// The download doesn't match the size / checksum the server recorded.
class CloudDamaged extends CloudException {
  const CloudDamaged();
}

/// Network / server trouble; nothing was changed by this app.
class CloudFailed extends CloudException {
  const CloudFailed(this.reason);
  final String reason;
  @override
  String toString() => 'CloudFailed($reason)';
}

// ── data ─────────────────────────────────────────────────────────────────
/// One song's copy in the cloud (a row of GET /projects?include=meta).
class CloudCopy {
  const CloudCopy({
    required this.projectId,
    required this.title,
    required this.updatedAt,
    required this.sizeBytes,
    required this.key,
    required this.sha256,
    required this.audioIncluded,
    required this.takes,
    required this.rawUpdatedAt,
  });

  final String projectId;
  final String title;
  final DateTime updatedAt;
  final int sizeBytes;
  final String key;
  final String sha256;
  final bool audioIncluded;
  final int takes;

  /// The server's own string for [updatedAt], sent back verbatim as
  /// `expected_updated_at` (no precision lost in a round trip).
  final String rawUpdatedAt;

  static CloudCopy? fromJson(Map<String, dynamic> j) {
    final meta = j['meta'];
    if (meta is! Map || meta['format'] != 'humtrack') return null;
    final raw = '${j['updated_at']}';
    return CloudCopy(
      projectId: '${j['project_id']}',
      title: '${j['title']}',
      updatedAt: DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0),
      sizeBytes: (meta['size'] as num?)?.toInt() ?? 0,
      key: '${meta['key']}',
      sha256: '${meta['sha256']}',
      audioIncluded: meta['audioIncluded'] == true,
      takes: (meta['takes'] as num?)?.toInt() ?? 0,
      rawUpdatedAt: raw,
    );
  }
}

/// An uploaded (not yet committed) backup object.
class CloudUpload {
  const CloudUpload({
    required this.projectId,
    required this.title,
    required this.meta,
  });
  final String projectId;
  final String title;
  final Map<String, Object> meta;
}

/// Where this device's songs stand in the cloud: local song id → the cloud
/// copy it was last uploaded to / restored from. `looptap/cloud_links.json`
/// (app storage, written atomically).
class CloudLink {
  const CloudLink(this.projectId, this.updatedAt, this.audioIncluded);
  final String projectId;
  final String updatedAt; // server string
  final bool audioIncluded;

  Map<String, Object> toJson() => {
    'projectId': projectId,
    'updatedAt': updatedAt,
    'audioIncluded': audioIncluded,
  };
}

class CloudLinks {
  // Codex review 2 (2026-10-30):
  // C4 — one read-modify-write at a time (a process-wide chain) and a unique
  //      temp file per write, so parallel backups never race on one temp
  //      file or drop each other's links;
  // C5 — one file per account (`looptap/cloud_links/<owner>.json`): account
  //      B never sees (or sends) account A's cloud versions.
  static Future<void>? _tail;
  static var _active = 0;
  static var _seq = 0;

  static String _safe(String owner) =>
      owner.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<File> _file(String owner) async => File(
    '${(await LoopStorage.documentsDirectory()).path}/looptap/cloud_links/${_safe(owner)}.json',
  );

  /// One link operation at a time. Nothing is kept once the queue is idle,
  /// so a finished operation never holds up a later one.
  static Future<T> _serial<T>(Future<T> Function() op) async {
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

  static Future<Map<String, CloudLink>> _read(String owner) async {
    try {
      final f = await _file(owner);
      if (!await f.exists()) return {};
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return {
        for (final e in j.entries)
          if (e.value is Map)
            e.key: CloudLink(
              '${e.value['projectId']}',
              '${e.value['updatedAt']}',
              e.value['audioIncluded'] == true,
            ),
      };
    } catch (_) {
      return {}; // unreadable: treated as never uploaded (conflicts catch it)
    }
  }

  static Future<void> _write(String owner, Map<String, CloudLink> all) async {
    final f = await _file(owner);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.$pid-${_seq++}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}),
        flush: true,
      );
      await _replace(tmp, f.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Rename seam for tests (a Windows refusal can't be produced on demand).
  @visibleForTesting
  static Future<void> Function(File tmp, String target)? debugRename;

  /// Move [tmp] over [target]. Windows may refuse the replace for a moment
  /// while something (an indexer, antivirus, a reader) still has the target
  /// open (errno 5, Codex flutter-full-final.log): retry briefly. The target
  /// is never deleted first, so a failure leaves the previous links intact.
  static Future<void> _replace(File tmp, String target) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final rename = debugRename;
        if (rename != null) {
          await rename(tmp, target);
        } else {
          await tmp.rename(target);
        }
        return;
      } on FileSystemException {
        if (attempt >= 8) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
      }
    }
  }

  /// [owner]'s links (after any pending write).
  static Future<Map<String, CloudLink>> load(String owner) =>
      _serial(() => _read(owner));

  static Future<void> put(String owner, String songId, CloudLink? link) =>
      _serial(() async {
        final all = await _read(owner);
        if (link == null) {
          all.remove(songId);
        } else {
          all[songId] = link;
        }
        await _write(owner, all);
      });

  /// Forget [owner]'s links to a cloud copy that was deleted.
  static Future<void> removeProject(String owner, String projectId) =>
      _serial(() async {
        final all = await _read(owner);
        all.removeWhere((_, l) => l.projectId == projectId);
        await _write(owner, all);
      });
}

/// The signed-in account changed while a cloud action was running: it stops
/// before sending anything for, or writing anything into, the other account.
class CloudAccountChanged extends CloudException {
  const CloudAccountChanged();
}

// ── API ──────────────────────────────────────────────────────────────────
class CloudBackupApi {
  /// [api] talks to our backend and carries the account token (the app's
  /// engineApi.dio). [storage] talks to the signed R2 URLs and must carry
  /// NOTHING else — by default a bare Dio without interceptors or logging.
  ///
  /// [owner] is the account this API acts for, fixed when it is made;
  /// [currentOwner] reports who is signed in NOW — every request, link write
  /// and restore checks it and stops with [CloudAccountChanged] on a switch.
  CloudBackupApi(
    this.api, {
    required this.owner,
    this.currentOwner,
    Dio? storage,
  }) : storage =
          storage ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(minutes: 10),
              receiveTimeout: const Duration(minutes: 10),
            ),
          );

  final Dio api;
  final Dio storage;
  final String owner;
  final String? Function()? currentOwner;

  /// Another account is signed in now than the one this API acts for.
  bool get ownerChanged => currentOwner != null && currentOwner!() != owner;

  /// Throws [CloudAccountChanged] when another account is signed in now.
  void checkOwner() {
    final now = currentOwner?.call();
    if (currentOwner != null && now != owner) throw const CloudAccountChanged();
  }

  /// A call to our API for [owner] (Codex C5 boundaries): checked before it
  /// is sent and again when the answer arrives (an answer that comes back
  /// after a switch is dropped, never shown or used). `X-Expected-User` lets
  /// the server refuse it if the token attached on the way belongs to
  /// another account (a switch while the token was fetched).
  Future<Response<T>> _call<T>(Future<Response<T>> Function(Options o) send) async {
    checkOwner();
    try {
      final r = await send(Options(headers: {'X-Expected-User': owner}));
      checkOwner();
      return r;
    } on DioException {
      checkOwner();
      rethrow;
    }
  }

  Never _fail(Object e) {
    if (e is CloudException) throw e;
    checkOwner();
    if (e is DioException) {
      final code = e.response?.statusCode;
      final detail = e.response?.data is Map ? e.response!.data['detail'] : null;
      if (detail is Map && detail['error'] == 'account_mismatch') {
        throw const CloudAccountChanged();
      }
      switch (code) {
        case 401:
          throw const CloudSignInRequired();
        case 403:
          throw const CloudProRequired();
        case 404:
          throw const CloudUnavailable();
        case 412:
          if (detail is Map) {
            throw CloudQuotaExceeded(
              (detail['used'] as num?)?.toInt() ?? 0,
              (detail['quota'] as num?)?.toInt() ?? 0,
            );
          }
      }
      throw CloudFailed('http ${code ?? e.type.name}');
    }
    throw CloudFailed(e.runtimeType.toString());
  }

  /// Used / quota bytes; throws [CloudUnavailable] when the server lacks the
  /// feature or speaks an older contract.
  Future<({int used, int quota})> usage() async {
    try {
      final r = await _call((o) => api.get<Map<String, dynamic>>('/storage/usage', options: o));
      final j = r.data ?? const {};
      if (((j['contract'] as num?)?.toInt() ?? 0) < kCloudContract) {
        throw const CloudUnavailable();
      }
      return (
        used: (j['used_bytes'] as num).toInt(),
        quota: (j['quota_bytes'] as num).toInt(),
      );
    } catch (e) {
      _fail(e);
    }
  }

  Future<List<CloudCopy>> list() async {
    try {
      final r = await _call(
        (o) => api.get<List<dynamic>>(
          '/projects',
          queryParameters: const {'include': 'meta'},
          options: o,
        ),
      );
      return [
        for (final row in r.data ?? const [])
          if (row is Map<String, dynamic>)
            if (CloudCopy.fromJson(row) case final c?) c,
      ];
    } catch (e) {
      _fail(e);
    }
  }

  /// Upload [bytes] as the next version of [projectId]'s cloud copy and
  /// commit it. [expected] = the cloud version this device last saw (null:
  /// a first upload). Returns the server's new version string.
  Future<String> upload({
    required String projectId,
    required String title,
    required Uint8List bytes,
    required bool audioIncluded,
    required int takes,
    required int missingTakes,
    String? expected,
  }) async {
    await usage(); // feature + contract check before sending anything
    final Map<String, dynamic> grant;
    try {
      final r = await _call(
        (o) => api.post<Map<String, dynamic>>(
          '/storage/presign',
          data: {'project_id': projectId, 'size_bytes': bytes.length},
          options: o,
        ),
      );
      grant = r.data!;
    } catch (e) {
      _fail(e);
    }
    try {
      checkOwner(); // never send this account's bytes after a switch
      await storage.put<void>(
        grant['url'] as String,
        data: Stream.fromIterable([bytes]),
        options: Options(
          // exactly the signed headers — no account token to R2
          headers: {
            for (final e in (grant['headers'] as Map).entries)
              '${e.key}': '${e.value}',
          },
        ),
      );
    } on DioException catch (e) {
      throw CloudFailed('upload ${e.response?.statusCode ?? e.type.name}');
    }
    final upload = CloudUpload(
      projectId: projectId,
      title: title,
      meta: {
        'format': 'humtrack',
        'formatVersion': 1,
        'key': grant['key'] as String,
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'audioIncluded': audioIncluded,
        'takes': takes,
        'missingTakes': missingTakes,
        'songSchema': Song.kSchemaVersion,
      },
    );
    return commit(upload, expected: expected);
  }

  /// Commit an uploaded object ([expected] null = first upload).
  ///
  /// Idempotent from the app's side (Codex C1): when the answer is lost or
  /// the server can't tell (503 "commit_unknown", a timeout), the cloud copy
  /// is read back — if it is OUR bytes (same SHA-256) the commit happened.
  /// A conflict whose cloud copy is our bytes is the same case.
  Future<String> commit(CloudUpload upload, {String? expected}) async {
    try {
      final r = await _call(
        (o) => api.post<Map<String, dynamic>>(
          '/projects',
        data: {
            'project_id': upload.projectId,
            'title': upload.title,
            'meta': upload.meta,
            if (expected != null) 'expected_updated_at': expected,
            if (expected == null) 'expect_absent': true,
          },
          options: o,
        ),
      );
      return '${r.data!['updated_at']}';
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final detail = e.response?.data is Map ? e.response!.data['detail'] : null;
        if (detail is Map && detail['error'] == 'account_mismatch') {
          throw const CloudAccountChanged();
        }
        final cv = detail is Map ? detail['cloud_version'] : null;
        final cloud =
            cv is Map
                ? CloudCopy.fromJson({
                  ...cv.cast<String, dynamic>(),
                  'project_id': upload.projectId,
                })
                : null;
        // a retry after a lost answer: the cloud copy is already ours
        if (cloud != null && cloud.sha256 == upload.meta['sha256']) {
          return cloud.rawUpdatedAt;
        }
        throw CloudConflict(cloud: cloud, upload: upload);
      }
      final code = e.response?.statusCode;
      if (code == null || code >= 500) {
        final landed = await _committedAs(upload);
        if (landed != null) return landed;
      }
      _fail(e);
    } on CloudConflict {
      rethrow;
    } catch (e) {
      _fail(e);
    }
  }

  /// The cloud version string if [upload]'s bytes are the current copy.
  Future<String?> _committedAs(CloudUpload upload) async {
    try {
      final r = await _call(
        (o) => api.get<Map<String, dynamic>>('/projects/${upload.projectId}', options: o),
      );
      final copy = CloudCopy.fromJson(r.data ?? const {});
      if (copy != null && copy.sha256 == upload.meta['sha256']) {
        return copy.rawUpdatedAt;
      }
    } catch (_) {}
    return null;
  }

  /// The copy's bytes, checked against the recorded size and SHA-256.
  Future<Uint8List> download(CloudCopy copy) async {
    final String url;
    try {
      final r = await _call(
        (o) => api.post<Map<String, dynamic>>(
          '/storage/presign_get',
          data: {'key': copy.key},
          options: o,
        ),
      );
      url = r.data!['url'] as String;
    } catch (e) {
      _fail(e);
    }
    final Uint8List bytes;
    try {
      checkOwner();
      final r = await storage.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      bytes = Uint8List.fromList(r.data ?? const []);
    } on DioException catch (e) {
      throw CloudFailed('download ${e.response?.statusCode ?? e.type.name}');
    }
    if (bytes.length != copy.sizeBytes ||
        sha256.convert(bytes).toString() != copy.sha256) {
      throw const CloudDamaged();
    }
    return bytes;
  }

  Future<void> delete(String projectId) async {
    try {
      await _call((o) => api.delete<void>('/projects/$projectId', options: o));
    } catch (e) {
      _fail(e);
    }
  }
}

// ── song-level actions ───────────────────────────────────────────────────
/// The cloud project id of a song for [api]'s account: the link if it has
/// one, else its own id.
Future<String> cloudProjectIdFor(CloudBackupApi api, Song song) async =>
    (await CloudLinks.load(api.owner))[song.id]?.projectId ?? song.id;

/// Back [song] up (recordings only with [includeAudio]). Throws
/// [CloudConflict] when the cloud copy moved on; resolve with
/// [keepThisDevice] / [restoreCopy] / [backupAsNewCopy].
Future<CloudLink> backupSong(
  CloudBackupApi api,
  Song song, {
  required bool includeAudio,
}) async {
  final link = (await CloudLinks.load(api.owner))[song.id];
  final built = await buildProjectBackup(song, includeAudio: includeAudio);
  final projectId = link?.projectId ?? song.id;
  final version = await api.upload(
    projectId: projectId,
    title: song.title,
    bytes: built.bytes,
    audioIncluded: includeAudio,
    takes: built.takes,
    missingTakes: built.missing,
    expected: link?.updatedAt,
  );
  final next = CloudLink(projectId, version, includeAudio);
  api.checkOwner();
  await CloudLinks.put(api.owner, song.id, next);
  return next;
}

/// "Keep this device's": commit the already-uploaded object over the cloud
/// version the conflict showed (or as a new copy when it was deleted).
Future<CloudLink> keepThisDevice(
  CloudBackupApi api,
  Song song,
  CloudConflict conflict,
) async {
  final version = await api.commit(
    conflict.upload,
    expected: conflict.cloud?.rawUpdatedAt,
  );
  final next = CloudLink(
    conflict.upload.projectId,
    version,
    conflict.upload.meta['audioIncluded'] == true,
  );
  api.checkOwner();
  await CloudLinks.put(api.owner, song.id, next);
  return next;
}

/// "Keep both": this device's song becomes a separate cloud copy.
Future<CloudLink> backupAsNewCopy(
  CloudBackupApi api,
  Song song, {
  required bool includeAudio,
}) async {
  // a first upload under a new id; the song is linked to it only once the
  // upload is committed (a failure leaves the old link as it was)
  final copyId = 'lt${DateTime.now().millisecondsSinceEpoch}c';
  final built = await buildProjectBackup(song, includeAudio: includeAudio);
  final version = await api.upload(
    projectId: copyId,
    title: song.title,
    bytes: built.bytes,
    audioIncluded: includeAudio,
    takes: built.takes,
    missingTakes: built.missing,
  );
  final next = CloudLink(copyId, version, includeAudio);
  api.checkOwner();
  await CloudLinks.put(api.owner, song.id, next);
  return next;
}

/// "Take the cloud's" / restore on a new device: the copy becomes a NEW local
/// song (existing songs untouched), linked to the copy so later backups from
/// here continue it. [missing] = recordings not in the copy (left silent).
Future<({Song song, int missing})> restoreCopy(
  CloudBackupApi api,
  LoopStore store,
  CloudCopy copy,
) async {
  final bytes = await api.download(copy);
  // never into the library of an account that signed in meanwhile (C5)
  api.checkOwner();
  final res = await importProjectBackup(store, bytes);
  await CloudLinks.put(
    api.owner,
    res.song.id,
    CloudLink(copy.projectId, copy.rawUpdatedAt, copy.audioIncluded),
  );
  return res;
}

/// Delete the cloud copy only (local songs stay); forgets links to it.
Future<void> deleteCopy(CloudBackupApi api, String projectId) async {
  await api.delete(projectId);
  await CloudLinks.removeProject(api.owner, projectId);
}
