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
  });

  final String id;
  String title;
  DateTime updatedAt;
  int trackCount;
  double durationSec;

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
        out.add(ProjectMeta.fromJson(meta));
      } catch (e) {
        debugPrint('[storage] skip malformed meta at ${entry.path}: $e');
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
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
