// An in-memory cloud backup server + R2 bucket behind a Dio adapter, with
// the contract-1 rules the app relies on (signed PUT headers, create-only
// uploads, version-checked commits). The real server is tested in
// backend/tests/test_cloud_backup.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:humming/looptap/state/cloud_backup.dart';

const kFakeToken = 'ACCOUNT-TOKEN';

/// API (`https://api.test`, with the account token like main.dart) and
/// storage (bare) clients wired to [cloud], acting for [owner]; [signedIn]
/// (optional) reports who is signed in now.
CloudBackupApi fakeCloudApi(
  FakeCloud cloud, {
  String owner = 'user-a',
  String? Function()? signedIn,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = cloud
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          o.headers['Authorization'] = 'Bearer $kFakeToken';
          h.next(o);
        },
      ),
    );
  return CloudBackupApi(
    dio,
    owner: owner,
    currentOwner: signedIn,
    storage: Dio()..httpClientAdapter = cloud,
  );
}

/// The server + bucket stand-in.
class FakeCloud implements HttpClientAdapter {
  final rows = <String, Map<String, dynamic>>{};
  final objects = <String, Uint8List>{};
  final issued = <String, Map<String, String>>{}; // url → signed headers
  final requests = <RequestOptions>[];
  bool featureOn = true;
  int contract = 1;
  bool pro = true;
  int quota = 1 << 30;
  bool failPut = false;
  bool corruptDownload = false;

  /// Answer every API call 409 account_mismatch (the token on the way was
  /// another account's; server guard, Codex C5).
  bool accountMismatch = false;

  /// Commit, then answer 503 as if the answer was lost (Codex C1).
  bool loseCommitResponse = false;

  /// Called on each storage PUT / GET (e.g. to switch accounts mid-action).
  void Function()? onPut, onGet;
  var _n = 0;

  int get used => objects.values.fold(0, (a, b) => a + b.length);
  int get puts => requests.where((r) => r.method == 'PUT').length;

  ResponseBody _json(Object? body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(o);
    final body = <int>[];
    if (requestStream != null) {
      await for (final c in requestStream) {
        body.addAll(c);
      }
    }
    final uri = o.uri;
    if (uri.host == 'r2.test') {
      if (o.method == 'PUT') onPut?.call();
      if (o.method == 'GET') onGet?.call();
      if (o.method == 'PUT') {
        final signed = issued[uri.toString()];
        if (signed == null || failPut) return ResponseBody.fromString('', 500);
        for (final e in signed.entries) {
          if ('${o.headers[e.key] ?? o.headers[e.key.toLowerCase()]}' != e.value) {
            return ResponseBody.fromString('', 403);
          }
        }
        final key = uri.path.substring(1);
        if (objects.containsKey(key)) return ResponseBody.fromString('', 412);
        if (body.length.toString() != signed['Content-Length']) {
          return ResponseBody.fromString('', 403);
        }
        objects[key] = Uint8List.fromList(body);
        return ResponseBody.fromString('', 200);
      }
      final data = objects[uri.path.substring(1)];
      if (data == null) return ResponseBody.fromString('', 404);
      final out = Uint8List.fromList(data);
      if (corruptDownload) out[out.length ~/ 2] ^= 1;
      return ResponseBody.fromBytes(out, 200);
    }
    // our API
    if (!featureOn) return _json({'detail': 'Not Found'}, 404);
    if (accountMismatch) {
      return _json({'detail': {'error': 'account_mismatch'}}, 409);
    }
    final j = body.isEmpty ? null : jsonDecode(utf8.decode(body));
    final path = uri.path;
    if (path == '/storage/usage') {
      return _json({
        'used_bytes': used,
        'quota_bytes': quota,
        if (contract > 0) 'contract': contract,
      }, 200);
    }
    if (path == '/storage/presign') {
      if (!pro) return _json({'detail': 'Pro'}, 403);
      final size = j['size_bytes'] as int;
      if (used + size > quota) {
        return _json({'detail': {'error': 'quota_exceeded', 'used': used, 'quota': quota}}, 412);
      }
      final key = 'vocals/u/${j['project_id']}/up-${_n++}.humtrack';
      final url = 'https://r2.test/$key?X-Amz-Signature=SIG';
      final headers = {
        'Content-Type': 'application/octet-stream',
        'Content-Length': '$size',
        'If-None-Match': '*',
      };
      issued[url] = headers;
      return _json({'url': url, 'headers': headers, 'key': key}, 200);
    }
    if (path == '/projects' && o.method == 'GET') {
      return _json([for (final r in rows.values) r], 200);
    }
    if (path == '/projects' && o.method == 'POST') {
      final pid = j['project_id'] as String;
      final meta = (j['meta'] as Map).cast<String, dynamic>();
      final up = objects[meta['key']];
      if (up == null) return _json({'detail': 'missing'}, 404);
      final cur = rows[pid];
      final expected = j['expected_updated_at'];
      final absent = j['expect_absent'] == true;
      final ok = cur == null ? absent : (!absent && expected == cur['updated_at']);
      if (!ok) {
        return _json({
          'detail': {
            'error': 'conflict',
            'cloud_version': cur == null
                ? null
                : {'title': cur['title'], 'size_bytes': cur['size_bytes'], 'updated_at': cur['updated_at'], 'meta': cur['meta']},
          },
        }, 409);
      }
      final bk = 'vocals/u/$pid/bk-${_n++}.humtrack';
      objects[bk] = up;
      objects.remove(meta['key']);
      if (cur != null) objects.remove(cur['meta']['key']);
      final at = '2026-10-30T09:00:00.${(_n * 1000).toString().padLeft(6, '0')}+00:00';
      rows[pid] = {
        'project_id': pid,
        'title': j['title'],
        'size_bytes': up.length,
        'uploaded_at': at,
        'updated_at': at,
        'meta': {...meta, 'key': bk},
      };
      if (loseCommitResponse) return _json({'detail': {'error': 'commit_unknown'}}, 503);
      return _json({'project_id': pid, 'updated_at': at, 'used_bytes': used, 'quota_bytes': quota}, 200);
    }
    if (path == '/storage/presign_get') {
      return _json({'url': 'https://r2.test/${j['key']}?X-Amz-Signature=SIG'}, 200);
    }
    if (path.startsWith('/projects/') && o.method == 'GET') {
      final row = rows[path.substring('/projects/'.length)];
      return row == null ? _json({'detail': 'project not found'}, 404) : _json(row, 200);
    }
    if (path.startsWith('/projects/') && o.method == 'DELETE') {
      final row = rows.remove(path.substring('/projects/'.length));
      if (row != null) objects.remove(row['meta']['key']);
      return ResponseBody.fromString('', 204);
    }
    return _json({'detail': 'Not Found'}, 404);
  }

  @override
  void close({bool force = false}) {}
}
