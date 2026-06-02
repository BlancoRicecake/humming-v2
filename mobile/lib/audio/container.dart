// 녹음 컨테이너(파일 확장자) 유틸.
//
// 배경: record 6.2.1 의 AudioEncoder.opus 는 플랫폼별로 컨테이너가 다르다.
//   • iOS     → CAF 컨테이너에 Opus payload  (재생: AVPlayer = .caf OK, .ogg X)
//   • Android → Ogg 컨테이너에 Opus payload  (재생: MediaPlayer = .ogg OK, .caf X)
// 단일 확장자 통일이 불가능해 플랫폼 분기 헬퍼로 캡슐화한다.
//
// 백엔드 ffmpeg pipe 디코더는 magic bytes 로 자동 판별하므로 분석은 영향 없음
// (filename 무시). 클라이언트 측 audioplayers 재생만 확장자에 민감 →
// 파일 생성 시 올바른 확장자를 붙여 저장한다.
//
// AAC 폴백(opus 미지원 단말)도 같은 헬퍼로 .m4a 를 돌려준다 — record 의
// AudioEncoder.aacLc 는 iOS/Android 모두 m4a 컨테이너.
import 'dart:io';

/// Opus 컨테이너 확장자 — iOS=.caf, Android=.ogg.
String opusContainerExt() => Platform.isIOS ? '.caf' : '.ogg';

/// 현재 녹음 인코더에 맞는 컨테이너 확장자.
/// 호출자가 인코더 폴백 여부를 미리 알 수 없으므로, 기본은 opus 컨테이너 가정.
/// (AAC LC 폴백 시 record 가 임의로 .m4a 로 쓸 수 있지만 우리는 사후
///  파일 매칭 fallback 으로 보완 — `findVocalFile` 참고.)
String audioContainerExt() => opusContainerExt();

/// 알려진 보컬/녹음 컨테이너 확장자 — 신규(.caf/.ogg/.opus/.m4a) +
/// 레거시(.wav: 과거 빌드가 Opus payload 를 .wav 로 저장한 흔적).
const List<String> kKnownVocalExts = <String>[
  '.caf',
  '.ogg',
  '.opus',
  '.m4a',
  '.wav',
];

/// 디스크에 저장된 보컬 파일 후보 경로(확장자 후보군) 중 실제 존재하는 첫 파일 반환.
/// 과거 빌드에서 `.wav` 로 저장된 Opus payload 도 graceful fallback.
///
/// [basePathNoExt] 예: `<docs>/projects/<pid>/vocals/chunk_42`
Future<File?> findExistingByExt(String basePathNoExt) async {
  for (final ext in kKnownVocalExts) {
    final f = File('$basePathNoExt$ext');
    if (await f.exists()) return f;
  }
  return null;
}
