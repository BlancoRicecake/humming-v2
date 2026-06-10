// 로컬 key/value 영속화 — cloud_prefs.json (Documents 디렉터리, 단일 JSON).
// shared_preferences 패키지 추가를 피하기 위한 가벼운 저장소. 현재는 LocaleService 가
// 언어 설정('locale')을 저장/로드하는 데 사용한다. (구 프로젝트 영속화 코드는 레거시
// 정리 때 제거됨 — 새 앱은 lib/looptap/state/loop_storage.dart 를 사용.)
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalStorage {
  LocalStorage._();
  static final LocalStorage instance = LocalStorage._();

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
}
