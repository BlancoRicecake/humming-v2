// 녹음 라이브러리 서비스 — temp / library 두 단계 보관.
//
// 핵심 개념:
//   • temp     — 모든 녹음이 처음 저장되는 곳. TTL 만료 또는 트랙 삭제 시 자동 정리.
//   • library  — 사용자가 "라이브러리에 저장" 토글로 옮긴 영구 보관본. 수동 삭제만.
//
// 디렉터리:
//   <Documents>/recordings/temp/      — 임시 녹음 (확장자: opusContainerExt)
//   <Documents>/recordings/library/   — 영구 녹음
//   <Documents>/recordings/index.json — 메타데이터(파형/길이/마지막 악기 등)
//
// 엣지 케이스:
//   • 재녹음 후 "사용" 선택 → old temp 삭제, new temp 가 현재 녹음.
//   • 재녹음 후 "버리기" 선택 → new temp 만 삭제. **old temp 는 절대 건드리지 않음.**
//   • library 항목은 어떤 자동 삭제도 일어나지 않음.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 라이브러리/임시 한 항목.
class RecordingEntry {
  RecordingEntry({
    required this.id,
    required this.path,
    required this.isSaved,
    required this.recordedAt,
    required this.duration,
    required this.peaks,
    this.lastProgram,
    this.label,
  });

  final String id; // 자체 생성 UUID-like id (ms + random)
  String path;     // 실제 파일 경로 (temp ↔ library 이동 시 갱신)
  bool isSaved;    // false=temp, true=library
  final DateTime recordedAt;
  final double duration;
  final List<double> peaks;
  int? lastProgram; // 마지막 사용 악기 program 번호 (0..127)
  String? label;    // 사용자 지정 라벨 (없으면 날짜로 표기)

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'is_saved': isSaved,
        'recorded_at': recordedAt.toIso8601String(),
        'duration': duration,
        'peaks': peaks,
        if (lastProgram != null) 'last_program': lastProgram,
        if (label != null) 'label': label,
      };

  static RecordingEntry fromJson(Map<String, dynamic> j) => RecordingEntry(
        id: j['id'] as String,
        path: j['path'] as String,
        isSaved: (j['is_saved'] as bool?) ?? false,
        recordedAt: DateTime.tryParse((j['recorded_at'] ?? '') as String) ?? DateTime.now(),
        duration: ((j['duration'] as num?) ?? 0).toDouble(),
        peaks: ((j['peaks'] ?? const []) as List).map((e) => (e as num).toDouble()).toList(),
        lastProgram: (j['last_program'] as num?)?.toInt(),
        label: j['label'] as String?,
      );
}

class RecordingLibrary {
  RecordingLibrary._();
  static final RecordingLibrary instance = RecordingLibrary._();

  final List<RecordingEntry> _entries = [];
  Directory? _rootDir;
  Directory? _tempDir;
  Directory? _libDir;
  File? _indexFile;
  bool _ready = false;
  Completer<void>? _initOnce;

  /// 부트 시 1회 호출. 디렉터리 생성 + index.json 로드.
  Future<void> init() {
    if (_initOnce != null) return _initOnce!.future;
    _initOnce = Completer<void>();
    _doInit().then((_) => _initOnce!.complete()).catchError((e, st) {
      debugPrint('[reclib] init FAILED: $e');
      _initOnce!.complete();
    });
    return _initOnce!.future;
  }

  Future<void> _doInit() async {
    final docs = await getApplicationDocumentsDirectory();
    _rootDir = Directory('${docs.path}/recordings');
    _tempDir = Directory('${_rootDir!.path}/temp');
    _libDir = Directory('${_rootDir!.path}/library');
    if (!_rootDir!.existsSync()) _rootDir!.createSync(recursive: true);
    if (!_tempDir!.existsSync()) _tempDir!.createSync(recursive: true);
    if (!_libDir!.existsSync()) _libDir!.createSync(recursive: true);
    _indexFile = File('${_rootDir!.path}/index.json');
    await _loadIndex();
    // iOS 시뮬레이터 재빌드/앱 업데이트 시 컨테이너 ID 가 바뀌어 옛 절대경로가
    // 무효화된다. 인덱스의 path 가 현재 Documents/recordings 하위가 아닐 경우
    // 파일명만 추출해 현재 root 로 재바인딩한다 (basename 보존).
    var migrated = 0;
    for (final e in _entries) {
      final basename = p.basename(e.path);
      final wantDir = e.isSaved ? _libDir!.path : _tempDir!.path;
      final reBound = p.join(wantDir, basename);
      if (e.path != reBound) {
        e.path = reBound;
        migrated++;
      }
    }
    if (migrated > 0) {
      await _saveIndex();
      debugPrint('[reclib] rebound $migrated entries to current Documents root');
    }
    _ready = true;
    debugPrint('[reclib] init ok — temp=${tempEntries.length} library=${savedEntries.length}');
  }

  Future<void> _loadIndex() async {
    _entries.clear();
    if (_indexFile == null || !_indexFile!.existsSync()) return;
    try {
      final raw = await _indexFile!.readAsString();
      final j = jsonDecode(raw);
      if (j is Map && j['entries'] is List) {
        for (final e in (j['entries'] as List)) {
          if (e is Map<String, dynamic>) {
            _entries.add(RecordingEntry.fromJson(e));
          }
        }
      }
    } catch (e) {
      debugPrint('[reclib] index parse failed: $e');
    }
  }

  Future<void> _saveIndex() async {
    if (_indexFile == null) return;
    final body = {'entries': _entries.map((e) => e.toJson()).toList()};
    await _indexFile!.writeAsString(jsonEncode(body), flush: true);
  }

  bool get isReady => _ready;

  Directory? get tempDir => _tempDir;
  Directory? get libraryDir => _libDir;

  List<RecordingEntry> get savedEntries =>
      List.unmodifiable(_entries.where((e) => e.isSaved).toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt)));
  List<RecordingEntry> get tempEntries =>
      List.unmodifiable(_entries.where((e) => !e.isSaved).toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt)));

  RecordingEntry? entryById(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  String _newId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    // 짧은 무작위 suffix 추가 — 같은 ms 두 번 호출돼도 충돌 없게.
    final rnd = (ms ^ identityHashCode(Object())).toRadixString(16).padLeft(8, '0').substring(0, 6);
    return 'r_${ms.toRadixString(16)}_$rnd';
  }

  /// 원본 [sourcePath] (마이크 녹음 결과) 를 temp 디렉터리로 복사하고 index 갱신.
  /// 호출자는 분석에 사용했던 그 파일을 그대로 넘기면 된다 — 원본은 보존되며,
  /// 라이브러리가 자체 사본을 보관한다(트랙/프로젝트 흐름과 독립).
  Future<RecordingEntry> saveTemp(
    String sourcePath,
    double duration,
    List<double> peaks, {
    int? lastProgram,
  }) async {
    await init();
    final id = _newId();
    final src = File(sourcePath);
    final ext = _extOf(sourcePath);
    final dst = File('${_tempDir!.path}/$id$ext');
    try {
      if (src.existsSync()) {
        await src.copy(dst.path);
      } else {
        debugPrint('[reclib] saveTemp: source missing $sourcePath — entry without copy');
      }
    } catch (e) {
      debugPrint('[reclib] saveTemp copy FAILED: $e');
    }
    final entry = RecordingEntry(
      id: id,
      path: dst.path,
      isSaved: false,
      recordedAt: DateTime.now(),
      duration: duration,
      peaks: peaks,
      lastProgram: lastProgram,
    );
    _entries.add(entry);
    await _saveIndex();
    debugPrint('[reclib] saveTemp id=$id dur=${duration.toStringAsFixed(1)}s');
    return entry;
  }

  /// temp 항목을 라이브러리로 승격(파일은 library/ 로 이동).
  Future<RecordingEntry?> saveToLibrary(String entryId, {String? label}) async {
    await init();
    final e = entryById(entryId);
    if (e == null) return null;
    if (e.isSaved) {
      // 이미 라이브러리 — 라벨만 갱신.
      if (label != null && label.isNotEmpty) {
        e.label = label;
        await _saveIndex();
      }
      return e;
    }
    final ext = _extOf(e.path);
    final newPath = '${_libDir!.path}/${e.id}$ext';
    try {
      final f = File(e.path);
      if (f.existsSync()) {
        await f.rename(newPath);
      }
    } catch (e2) {
      // rename 이 cross-device 등으로 실패할 수 있음 — copy + delete fallback.
      try {
        final f = File(e.path);
        if (f.existsSync()) {
          await f.copy(newPath);
          await f.delete();
        }
      } catch (e3) {
        debugPrint('[reclib] saveToLibrary move FAILED: $e3');
      }
    }
    e.path = newPath;
    e.isSaved = true;
    if (label != null && label.isNotEmpty) e.label = label;
    await _saveIndex();
    debugPrint('[reclib] saveToLibrary id=$entryId');
    return e;
  }

  /// temp 항목 삭제. 라이브러리 항목은 무시(보호).
  Future<void> deleteTemp(String entryId) async {
    await init();
    final e = entryById(entryId);
    if (e == null) return;
    if (e.isSaved) {
      debugPrint('[reclib] deleteTemp: skip library entry $entryId');
      return;
    }
    try {
      final f = File(e.path);
      if (f.existsSync()) await f.delete();
    } catch (e2) {
      debugPrint('[reclib] deleteTemp file: $e2');
    }
    _entries.remove(e);
    await _saveIndex();
  }

  /// 라이브러리 항목 삭제(영구).
  Future<void> deleteFromLibrary(String entryId) async {
    await init();
    final e = entryById(entryId);
    if (e == null || !e.isSaved) return;
    try {
      final f = File(e.path);
      if (f.existsSync()) await f.delete();
    } catch (e2) {
      debugPrint('[reclib] deleteFromLibrary file: $e2');
    }
    _entries.remove(e);
    await _saveIndex();
  }

  /// 사용자 지정 라벨 갱신. [label]=null 또는 빈 문자열이면 라벨 제거(날짜 표시로 폴백).
  Future<void> rename(String entryId, String? label) async {
    await init();
    final e = entryById(entryId);
    if (e == null) return;
    final trimmed = label?.trim();
    e.label = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await _saveIndex();
    debugPrint('[reclib] rename id=$entryId label=${e.label}');
  }

  /// 트랙의 [lastProgram] 등 메타 갱신.
  Future<void> updateLastProgram(String entryId, int program) async {
    await init();
    final e = entryById(entryId);
    if (e == null) return;
    e.lastProgram = program;
    await _saveIndex();
  }

  /// TTL 정리. [ttlDays] 가 999 면 정리 안 함(영구 모드).
  /// 영향 범위는 temp 만. 라이브러리는 절대 손대지 않는다.
  Future<int> cleanupExpiredTemp(int ttlDays) async {
    await init();
    if (ttlDays >= 999) return 0;
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(days: ttlDays));
    final victims = _entries.where((e) => !e.isSaved && e.recordedAt.isBefore(cutoff)).toList();
    for (final v in victims) {
      try {
        final f = File(v.path);
        if (f.existsSync()) await f.delete();
      } catch (e) {
        debugPrint('[reclib] cleanup file: $e');
      }
      _entries.remove(v);
    }
    if (victims.isNotEmpty) {
      await _saveIndex();
      debugPrint('[reclib] cleanup removed ${victims.length} temp(s) older than ${ttlDays}d');
    }
    return victims.length;
  }

  String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot <= 0) return '';
    return path.substring(dot);
  }
}
