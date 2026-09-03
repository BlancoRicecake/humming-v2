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
// 왜 AAC 대신 Opus 인가:
//   AAC LC(.m4a) 는 컨테이너 끝에 `moov` atom 을 써야 finalize 가 끝나는데,
//   record 패키지의 Android 구현이 stop() 반환 시점에 flush 가 끝나지 않은
//   채로 path 를 돌려주는 경우가 있다. 그 상태로 업로드하면 서버 ffmpeg 가
//   "partial file" 로 거부 (실제 운영 로그에서 재현 확인됨).
//   Opus(CAF/OGG) 는 streaming-friendly 컨테이너라 finalize race 가 없다.
//
// 파일 생성 시점부터 올바른 확장자를 붙이는 게 안전 (record 가 확장자로
// 컨테이너를 판단하는 시점이 있음).
import 'dart:io';

/// Opus 컨테이너 확장자 — iOS=.caf, Android=.ogg.
String opusContainerExt() => Platform.isIOS ? '.caf' : '.ogg';

/// Opus 녹음 가능 여부. Android 는 API 29(Q) 미만에서 record_android 가
/// Opus 인코더를 거부(IllegalAccessException)하므로 AAC-LC 로 폴백해야 한다.
/// [androidSdkInt] 가 null(= iOS / 조회 실패)이면 Opus 로 간주.
bool opusSupported(int? androidSdkInt) =>
    androidSdkInt == null || androidSdkInt >= 29;

/// 압축 테이크 파일 확장자 — Opus 면 플랫폼 컨테이너(.caf/.ogg), 아니면 AAC-LC
/// 의 .m4a. 백엔드는 magic bytes 로 컨테이너를 판별하므로 어느 쪽이든 분석 가능.
String takeContainerExt({required bool opus}) =>
    opus ? opusContainerExt() : '.m4a';
