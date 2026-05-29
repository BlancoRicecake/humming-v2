// 출력 라우팅 조회 — 녹음 중 반주를 스피커로 틀면 마이크에 새어들어가므로,
// 헤드셋(유선/BT/USB)이 연결됐을 때만 반주 소리를 낸다.
import 'package:flutter/services.dart';

class AudioRoute {
  static const _ch = MethodChannel('humming/audio');

  /// 헤드셋(유선/블루투스/USB)이 연결돼 있으면 true. 실패 시 false(안전: 스피커 취급).
  static Future<bool> hasHeadset() async {
    try {
      final r = await _ch.invokeMethod<bool>('hasHeadset');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }
}
