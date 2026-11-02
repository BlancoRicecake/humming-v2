# FFmpeg · libsndfile 보안 수정 결과

최신 후속: [setuptools·OS 보안 점검](RUNTIME-SECURITY-2026-11-02.md).
setuptools 제거·최소 런타임·SQLite/zlib 수정 후 최종 후보는 `qa-20261102-osfinal2`다.
아래 native 후보와 남은 경고 수치는 해당 단계의 이력으로 보존한다.

2026-11-02 KST. **지정한 두 네이티브 문제는 새 로컬 서버 후보에서 수정·검증 완료.**
운영 서버·DB·Android 내부 테스트44·Windows 설치본은 변경하지 않았다.
push·PR·공개 배포도 하지 않았다. 전체 보안/출시 승인과는 구분한다.

## 수정

| 대상 | 조치 / 확인 근거 |
|---|---|
| FFmpeg CAF/MACE6, CVE-2026-66039 | 공식 **9.0.2** 소스 SHA-256 고정 및 PGP 서명 확인 후 직접 빌드. 실제 `mace_decode_frame()`의 int64 계산·INT_MAX 거부를 소스와 실행으로 확인 |
| libsndfile WAV/IMA, CVE-2026-37555 | **1.2.2 + upstream PR1123**의 WAV/close 연산 수정. 선행 AIFF 수정도 포함. 같은 곱셈이 남아 있던 seek 경계·바이트 위치·반환값은 로컬 companion 패치로 64비트 처리 |
| Python의 실제 로더 | SoundFile 0.14.0을 `--no-binary=soundfile`로 설치. wheel의 `_soundfile_data`가 없고 `/usr/local/lib/libsndfile.so.1.0.37`을 실제 매핑함을 확인. 바이너리 해시를 빌드 manifest와 비교 |
| 교체 시 보안 회귀 방지 | Debian에 포함됐던 Ogg 수정 CVE-2024-50612 보존. 추가 공지의 WAV 정렬 CVE-2026-88386, cue 이름 CVE-2026-109828, MAT4 크기 계산 CVE-2026-88372 upstream 수정도 이식 |
| 미사용 기능 | FFmpeg는 오디오 전용, file/pipe 전용으로 구성. 네트워크·장치·영상/이미지/자막 디코더·GPL/nonfree 구성 제외. libsndfile MPEG 인코더는 제외하고, MP3 입력은 FFmpeg로 처리 |

libsndfile은 버전을 임의로 올려 표시하지 않으며 **1.2.2**를 그대로 보고한다.
정확한 패치 목록·원본/이식본 해시·실제 바이너리 해시는 별도 manifest에 기록했다.
공식 WAV 수정은 `cdadf9a65fdc1f28da9d235eb443d5f5e57010d2`이다.
이전 공지에 연결된 `c32c090...`의 실제 내용은 SDS 수정이어서 그것을 WAV 수정으로
간주하지 않았다. 커밋 제목/패치 내용까지 대조해 적용했다.

정렬·cue·MAT4 패치는 1.2.2와 최신 upstream의 카운터/포인터/원래 표현식 차이만
맞춰 이식했다. 원본 패치와 이식 사유를 모두 보존했다. 모든 패치는 fuzz=0으로
적용하고, 적용 실패·소스 조건 불일치·회귀 실패 시 이미지 빌드를 중단한다.

## 실제 검증

| 범위 | 결과 / 한계 |
|---|---|
| libsndfile upstream CTest | **143개 통과**. shared 빌드가 기본적으로 테스트를 비활성화하므로 같은 패치 소스의 별도 static 테스트 타깃에서 실행. 테스트 0개도 실패 처리 |
| 실제 FFmpeg MACE 디코더 | **3개 경계 검사 통과**. 실제 decoder 소스를 포함한 테스트를 UBSan으로 컴파일. INT_MAX를 넘는 출력 샘플 수는 할당/입력 접근 전에 AVERROR_INVALIDDATA로 거부. 정상 MACE6 CAF도 별도로 디코딩 |
| WAV 64비트 회귀 | 수정 전 이미지에서는 가상 파일 열기 실패. 수정 후 **2,500,050,000 프레임**을 정확히 보고하고 INT_MAX를 넘는 위치 seek/read 통과. 1.25GB 가상 파일은 디스크에 쓰거나 통째로 할당하지 않음 |
| 최종 이미지 API | **29개 검사 통과**, 1GiB/1CPU, 외부 네트워크 차단. WAV PCM16/float/IMA, Ogg Opus, M4A AAC, MP4 Opus, CAF PCM/ALAC, MP3, FLAC, AIFF, AU, WebM Opus, 오토튠·MIDI 포함 |
| 디코더 구분 | 응답의 `decoded_via`도 확인해, 깨진 FFmpeg를 SoundFile fallback이 가리는 결과를 통과시키지 않음. 실제 MP3·M4A·Opus는 FFmpeg, WAV는 패치된 SoundFile 경로 확인 |
| 요청 제한 | 기본 10/min 제한 유지. 확장 검사에서 실제 429 발생 후 제한 시간이 지난 뒤 계속 진행. 운영 rate-limit 코드를 바꾸지 않음 |
| 전체 백엔드 | **335 통과 / 11 skip / 실패0**. 최종 Linux 이미지의 실제 네이티브 라이브러리로 실행. 일회성 로컬 PostgreSQL과 내부 Docker network 사용 후 정리. Windows venv의 이전 결과를 재사용한 것이 아님 |
| 음원·보안 경계 | 실제 음원11개·Range206/416·다운로드 SHA-256·비루트·비밀 파일 부재·cloud OFF·HLS 거부와 오류 원문 미반환 통과. 사람의 청취·기기 테스트를 대신하지 않음 |

MPEG 인코더 제외 여부는 형식 메타데이터 조회만으로 판단하지 않았다.
`sf.check_format()`은 실제 encoder 존재와 달리 참을 반환할 수 있었다.
합성 데이터의 실제 MPEG 쓰기가 “unimplemented format”(code18)로 거부되는 것을
확인했다. MP3 **읽기**는 별도 실제 API 검사에서 정상 변환했다.

## 최종 후보와 증빙

- 로컬 태그: `humtrack-backend:qa-20261102-native`.
- 이미지 index digest: `sha256:dc9fd87951414fc36c95d810a165145b8bdc019c0028b143828749f108f037e2`.
- TAR: `artifacts/releases/backend-candidate-20261102-native/humtrack-backend-qa-20261102-native.tar`.
- 크기: **1,815,816,192 bytes**.
- TAR SHA-256: `509a69ddcd2f8428c2b30420eaae0412a0c579d4393e4742247dac04f1c9eb24`.
- OCI index→platform manifest→config/layer 해시 및 archive 해시 검증 완료.
- 현재 미커밋 파일을 포함한다. `backend-build-receipt.json`의 source SHA-256 목록과 함께 관리한다. Git HEAD만 같다고 동일 후보가 아니다.

증빙 디렉터리: `artifacts/native-security-2026-11-02/`.

- `native-compile-complete.log`: 공식 서명, 패치 적용, 143개 CTest, MACE UBSan3, 로더 회귀.
- `native-manifest.json`, `native-runtime.json`: 최종 이미지의 실제 해시·로드 경로·가상 WAV 결과.
- `container-probe.json`: API29·기본 요청 제한·격리 조건.
- `backend-linux-full.log`, `backend-linux-tests.json`: Linux335/11 및 실제 후보 image ID.
- `libsndfile-feature-proof.json`: 실제 MPEG 쓰기 거부.
- `image-vulnerabilities.json`, `python-audit.json`: 아래 제한을 포함한 검사 원본.

최종 이미지에는 대응 소스 아카이브·원본/이식 패치·빌드/설치 스크립트·회귀 소스·
설정·라이선스도 `/usr/local/share/humtrack-native/`에 넣었다.
재빌드 방법과 패치 기원은 [NATIVE-AUDIO-BUILD.md](NATIVE-AUDIO-BUILD.md)에 정리했다.
이전 `backend-candidate-20261102-security`와 그 이전 후보는 보존하되 이번 네이티브
수정본으로 사용하지 않는다.

## 남은 보안/출시 항목

Trivy 0.76.1의 유효기간 내 DB로 최종 TAR를 검사했다. OS 패키지는 302→115개,
OS 경고는 833→**298개 패키지-공지 행(고유144개)**으로 줄었다.
Critical0 / High50 / Medium95 / Low145 / Unknown8행이다.
이 감소에는 불필요한 의존성 제거가 포함되며, 모든 경고를 패치했다는 뜻이 아니다.

**소스로 직접 빌드한 FFmpeg/libsndfile은 일반 Debian 패키지 검사만으로 판정할 수 없다.**
해당 Debian 패키지가 사라진 것만으로 해결 처리하지 않았다. 위의 고정 소스·패치
검증·실제 매핑/해시·회귀 증거를 함께 사용한다. 알려지지 않은 모든 코덱 문제까지
배제한 침투 테스트 결과는 아니다.

Python 검사에는 기존 **setuptools와 내부 빌드 도구 공지4개**가 여전히 남는다.
pip-audit는 setuptools1개에서 3개 레코드(고유2개)를 보고한다.
pyworld의 `pkg_resources` 의존성을 정리한 뒤 제거하는 일과 나머지 OS 경고의
도달성 검토는 별도 보안 과제다. 전체 보안 체크 A10은 계속 미완료로 둔다.

운영 반영은 아직 하지 않았다. 실제 운영 배포·최종 로그인·앱/두 기기 왕복·Sentry·
스토어/Windows 출시 검증은 기존 체크리스트에 남는다. 사용자 요청 전에는
push·PR·공개 배포를 진행하지 않는다.

공식 근거: [FFmpeg 9.0.2 및 서명 키](https://ffmpeg.org/download.html),
[CAF/MACE 공지](https://security-tracker.debian.org/tracker/CVE-2026-66039),
[WAV 수정 PR1123](https://github.com/libsndfile/libsndfile/pull/1123),
[Ogg 수정](https://github.com/libsndfile/libsndfile/commit/4755f5bd7854611d92ad0f1295587b439f9950ba),
[WAV 정렬 수정](https://github.com/libsndfile/libsndfile/commit/474e4d328b1e6240b93ec6ed14efb7c6a44bee57),
[cue 수정](https://github.com/libsndfile/libsndfile/commit/1ccd2a18826722c3aa9ed54122ebff20e3b92b10),
[MAT4 수정 PR1167](https://github.com/libsndfile/libsndfile/pull/1167).
