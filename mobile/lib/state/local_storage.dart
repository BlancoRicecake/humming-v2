// 로컬 저장 — 프로젝트 메타(JSON) + 보컬 청크 Opus/WAV 파일.
//
// 구조:
//   <Documents>/projects/<project_id>/meta.json
//   <Documents>/projects/<project_id>/vocals/<chunk_id><ext>
//     ext = iOS .caf / Android .ogg  (record 6.2.1 Opus payload, audio/container.dart 참조)
//     레거시 빌드 흔적: .wav 확장자에 Opus payload 가 저장된 파일도 존재 — fallback 으로 호환.
//
// NSURLIsExcludedFromBackupKey 는 설정하지 않음 — Documents 디렉터리이므로
// iCloud / Google One 백업에 자연스럽게 포함된다(사용자 선택 = OS 백업 설정).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'project_store.dart';

/// 프로젝트 리스트 표시용 가벼운 메타데이터.
/// 카드 썸네일(컬러 hash) · 제목 · 트랙수 · 길이초 · 마지막 수정시간.
class ProjectMeta {
  ProjectMeta({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.trackCount,
    required this.durationSec,
    this.sizeBytes = 0,
  });

  final String id;
  String title;
  DateTime updatedAt;
  int trackCount;
  double durationSec;

  /// 디스크 사용량 — meta.json + vocals/* 합. listProjects() 가 채워넣음 (영속화는 안 함).
  /// 클라우드 업로드 전 사용량 예상 + 정렬 기준에 사용.
  int sizeBytes;

  /// 사람 친화 포맷: 512 B / 2.1 KB / 14.6 MB / 1.2 GB.
  String get sizeLabel => _formatBytes(sizeBytes);

  /// 카드 썸네일 색상 인덱스(0..3) — id 해시 기반 자동 분배.
  int get thumbIndex {
    var h = 0;
    for (final code in id.codeUnits) {
      h = (h * 31 + code) & 0x7fffffff;
    }
    return h % 4;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updated_at': updatedAt.toIso8601String(),
        'track_count': trackCount,
        'duration_sec': durationSec,
      };

  static ProjectMeta fromJson(Map<String, dynamic> j) => ProjectMeta(
        id: j['id'] as String,
        title: (j['title'] ?? 'Untitled') as String,
        updatedAt: DateTime.tryParse((j['updated_at'] ?? '') as String) ?? DateTime.now(),
        trackCount: (j['track_count'] as num?)?.toInt() ?? 0,
        durationSec: (j['duration_sec'] as num?)?.toDouble() ?? 0,
      );
}

String formatBytes(int bytes) => _formatBytes(bytes);

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const k = 1024;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  double v = bytes.toDouble();
  while (v >= k && i < units.length - 1) {
    v /= k;
    i++;
  }
  // 1 단위 미만(B, KB)은 정수, 그 이상은 소수 1자리.
  final s = i < 2 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '$s ${units[i]}';
}

class LocalStorage {
  LocalStorage._();
  static final LocalStorage instance = LocalStorage._();

  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/projects');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<Directory> _projectDir(String id) async {
    final root = await _root();
    final d = Directory('${root.path}/$id');
    if (!d.existsSync()) d.createSync(recursive: true);
    final v = Directory('${d.path}/vocals');
    if (!v.existsSync()) v.createSync(recursive: true);
    return d;
  }

  /// 메타 + 트랙 전체 직렬화 → meta.json.
  Future<void> saveProject(ProjectStore store) async {
    final id = store.projectId;
    final dir = await _projectDir(id);
    final tracks = store.tracks.map((t) {
      return {
        ...t.toJson(),
        'chunks': t.chunks.map((c) => c.toJson()).toList(),
      };
    }).toList();
    double duration = 0;
    for (final t in store.tracks) {
      for (final c in t.chunks) {
        if (c.timelineEnd > duration) duration = c.timelineEnd;
      }
    }
    final meta = ProjectMeta(
      id: id,
      title: store.title,
      updatedAt: DateTime.now(),
      trackCount: store.tracks.where((t) => t.hasRecording).length,
      durationSec: duration,
    );
    final body = {
      'meta': meta.toJson(),
      'bpm': store.bpm,
      'tracks': tracks,
    };
    final f = File('${dir.path}/meta.json');
    await f.writeAsString(jsonEncode(body), flush: true);
    debugPrint('[storage] saved project=$id tracks=${tracks.length} dur=${duration.toStringAsFixed(1)}s');
  }

  Future<List<ProjectMeta>> listProjects() async {
    final root = await _root();
    final out = <ProjectMeta>[];
    if (!root.existsSync()) return out;
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final f = File('${entry.path}/meta.json');
      if (!f.existsSync()) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final meta = (j['meta'] ?? {}) as Map<String, dynamic>;
        final m = ProjectMeta.fromJson(meta);
        m.sizeBytes = _dirSize(entry);
        out.add(m);
      } catch (e) {
        debugPrint('[storage] skip malformed meta at ${entry.path}: $e');
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 디렉터리 안 모든 파일 크기 합 (재귀). meta.json + vocals/*.caf|.ogg 등 포함.
  int _dirSize(Directory d) {
    int total = 0;
    try {
      for (final ent in d.listSync(recursive: true, followLinks: false)) {
        if (ent is File) {
          try {
            final len = ent.lengthSync();
            total += len;
          } catch (e) {
            debugPrint('[storage] _dirSize: cannot read ${ent.path}: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[storage] _dirSize: cannot list ${d.path}: $e');
    }
    debugPrint('[storage] _dirSize ${d.path}: ${_formatBytes(total)} ($total B)');
    return total;
  }

  /// 프로젝트 전체 로드 — store 에 반영(replace).
  Future<bool> loadProject(String id, ProjectStore store) async {
    final dir = Directory('${(await _root()).path}/$id');
    final f = File('${dir.path}/meta.json');
    if (!f.existsSync()) return false;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final meta = ProjectMeta.fromJson((j['meta'] ?? {}) as Map<String, dynamic>);
      final tracksJson = (j['tracks'] ?? []) as List;
      final tracks = <TrackData>[];
      int maxSeq = 0, maxChunk = 0;
      for (final tj in tracksJson) {
        final m = tj as Map<String, dynamic>;
        final t = TrackData.fromJson(m);
        // chunks 복원
        final cjs = (m['chunks'] ?? []) as List;
        t.chunks
          ..clear()
          ..addAll(cjs.map((e) => Chunk.fromJson(e as Map<String, dynamic>)));
        for (final c in t.chunks) {
          if (c.id > maxChunk) maxChunk = c.id;
        }
        if (t.id > maxSeq) maxSeq = t.id;
        tracks.add(t);
      }
      store.adoptLoaded(
        projectId: id,
        title: meta.title,
        bpm: (j['bpm'] as num?)?.toInt() ?? 90,
        tracks: tracks,
        trackSeq: maxSeq,
        chunkSeq: maxChunk,
      );
      return true;
    } catch (e) {
      debugPrint('[storage] loadProject FAILED: $e');
      return false;
    }
  }

  Future<void> deleteProject(String id) async {
    final dir = Directory('${(await _root()).path}/$id');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
      debugPrint('[storage] deleted project=$id');
    }
  }

  /// 모든 프로젝트 + 보컬 파일 통째 삭제 — 회원 탈퇴 시 호출.
  /// 호출 후 listProjects() 는 빈 배열.
  // ─── Cloud prefs (cloud_prefs.json) ────────────────────────────────────
  // 가벼운 key/value 영속화. shared_preferences 패키지 추가 회피 — Documents 디렉터리에
  // 단일 JSON 파일로 저장. autoSync 토글 등 cloud UI 가 사용.
  Future<File> _cloudPrefsFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/cloud_prefs.json');
  }

  Future<Map<String, dynamic>> readCloudPrefs() async {
    final f = await _cloudPrefsFile();
    if (!f.existsSync()) return const {};
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    return const {};
  }

  Future<void> writeCloudPrefs(Map<String, dynamic> patch) async {
    final cur = Map<String, dynamic>.from(await readCloudPrefs());
    cur.addAll(patch);
    final f = await _cloudPrefsFile();
    await f.writeAsString(jsonEncode(cur), flush: true);
  }

  // ─── Cloud download — 다운로드 받은 보컬/메타 영속화 ────────────────────
  /// 클라우드에서 받은 보컬 파일 바이트를 `vocals/<file_name>` 으로 저장.
  /// 디렉터리가 없으면 자동 생성. 반환값은 저장된 절대 경로.
  Future<String> saveDownloadedVocal({
    required String projectId,
    required String fileName,
    required List<int> bytes,
  }) async {
    final dir = await _projectDir(projectId);
    final f = File('${dir.path}/vocals/$fileName');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// 클라우드 다운로드 직후 로컬 meta.json 생성/덮어쓰기.
  /// 백엔드에서 받은 serverMeta 의 트랙 구조(이미 toJson 포맷)를 그대로 사용.
  Future<void> writeDownloadedMeta({
    required String projectId,
    required String title,
    required Map<String, dynamic> serverMeta,
  }) async {
    final dir = await _projectDir(projectId);
    // 서버 meta 가 기존 saveProject 포맷({meta, bpm, tracks}) 을 그대로 담고 있으면
    // 그대로 사용. 아니라면 최소 골격으로 wrap.
    Map<String, dynamic> body;
    if (serverMeta['tracks'] is List && serverMeta['meta'] is Map) {
      body = Map<String, dynamic>.from(serverMeta);
      // 다운로드 시각으로 updated_at 갱신.
      final m = Map<String, dynamic>.from(body['meta'] as Map);
      m['updated_at'] = DateTime.now().toIso8601String();
      m['id'] = projectId;
      m['title'] = title;
      body['meta'] = m;
    } else {
      body = {
        'meta': ProjectMeta(
          id: projectId,
          title: title,
          updatedAt: DateTime.now(),
          trackCount: 0,
          durationSec: 0,
        ).toJson(),
        'bpm': (serverMeta['bpm'] as num?)?.toInt() ?? 90,
        'tracks': serverMeta['tracks'] ?? [],
      };
    }
    final f = File('${dir.path}/meta.json');
    await f.writeAsString(jsonEncode(body), flush: true);
  }

  Future<void> wipeAll() async {
    final root = await _root();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
      debugPrint('[storage] wiped all projects');
    }
  }

  /// 프로젝트 복제 — 새 id 로 디렉터리 통째 복사 + meta.id/title 갱신.
  Future<ProjectMeta?> duplicateProject(ProjectMeta src) async {
    final root = await _root();
    final from = Directory('${root.path}/${src.id}');
    if (!from.existsSync()) return null;
    final newId = 'p_${DateTime.now().millisecondsSinceEpoch}';
    final to = Directory('${root.path}/$newId');
    to.createSync(recursive: true);
    for (final ent in from.listSync(recursive: true)) {
      final rel = ent.path.substring(from.path.length);
      final dst = '${to.path}$rel';
      if (ent is Directory) {
        Directory(dst).createSync(recursive: true);
      } else if (ent is File) {
        ent.copySync(dst);
      }
    }
    // meta.json 의 id/title 갱신.
    final mf = File('${to.path}/meta.json');
    if (mf.existsSync()) {
      final j = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
      final meta = (j['meta'] ?? {}) as Map<String, dynamic>;
      meta['id'] = newId;
      meta['title'] = '${src.title} (사본)';
      meta['updated_at'] = DateTime.now().toIso8601String();
      j['meta'] = meta;
      await mf.writeAsString(jsonEncode(j), flush: true);
      return ProjectMeta.fromJson(meta);
    }
    return null;
  }

  Future<void> renameProject(String id, String newTitle) async {
    final dir = Directory('${(await _root()).path}/$id');
    final f = File('${dir.path}/meta.json');
    if (!f.existsSync()) return;
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final meta = (j['meta'] ?? {}) as Map<String, dynamic>;
    meta['title'] = newTitle;
    meta['updated_at'] = DateTime.now().toIso8601String();
    j['meta'] = meta;
    await f.writeAsString(jsonEncode(j), flush: true);
  }
}
