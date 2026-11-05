# HumTrack 출시 전 보안 점검 — 2026-11-02

최신 심층 검토: [남은 OS25종의 서비스 영향](OS-IMPACT-REVIEW-2026-11-02.md).
수정/제거2·구성 완화2·조건/경로 미발견17·조건부 잔여 추적4. 최종 osimpact1
Linux335/11·API30 통과, raw OS57행·31종은 보존. 전체 보안 게이트는 미완료다.

최신 결과: [setuptools·서버 OS 점검](RUNTIME-SECURITY-2026-11-02.md).
Python 경고0, OS 원시63행·35종(구성요소 미포함10종 / 라이브러리 추적25종).
최종 Linux335/11·API30 통과. 전체 보안 게이트는 미완료다.

후속: [FFmpeg·libsndfile 수정 결과](NATIVE-AUDIO-SECURITY-2026-11-02.md).
아래 네이티브 두 차단 사항은 새 `backend-candidate-20261102-native`에서 로컬 수정·검증했다.
Linux335/11·API29·upstream143·MACE UBSan3 통과. 전체 보안 승인은 아직 보류한다.
이 문서의 초기 후보/스캔 수치는 점검 당시 이력이며 최신 후보는 후속 문서를 따른다.

판정: **출시 보류**. 로컬에서 재현한 두 문제는 수정했으나, 업로드 오디오를 처리하는 네이티브 라이브러리 경고가 남아 있다. 공개 배포·push·PR·운영 설정 변경은 하지 않았다. Android 내부 테스트 1.0.14(44)는 그대로다.

이 문서는 현재 작업 파일과 로컬 이미지의 제한된 점검 결과다. 전체 침투 테스트나 모든 취약점의 부재를 인증하지 않는다.

## 1. 재현·수정한 문제

| ID | 확인한 현상 / 영향 | 로컬 수정 | 검증 |
|---|---|---|---|
| SEC-01 | JWT 헤더의 `alg`가 배열이면 `.strip()`에서 AttributeError. 잘못된 토큰에 401 대신 서버 오류가 발생했다. 인증 우회는 재현하지 않았다. 중간 위험도로 분류 | `backend/app/deps.py`에서 알고리즘 문자열 타입 검사. 토큰/JWKS 오류 로그에 외부 문자열·예외 원문을 넣지 않음 | 배열·객체·숫자·불리언·null 5종 모두 401. 서명·issuer 테스트 포함 |
| SEC-02 | 디코딩 실패 시 업로드 앞 16바이트와 FFmpeg 오류 원문이 로그에 남고, 오류 원문은 400 응답에도 포함됐다. 녹음/업로드 내용과 경로가 노출될 수 있는 개인정보 문제. 중간 위험도로 분류 | `backend/app/analyze.py`에서 업로드 hex/문자열과 stderr 출력 제거. 로그는 크기·상태 코드, 응답은 고정 문구 | 합성 비밀 표식을 넣어 로그·응답에 남지 않는지 확인 |

추가 방어:

- `SUPABASE_URL`이 있는 환경에서 해당 프로젝트의 `/auth/v1` issuer를 필수 검증한다. HS256 및 비대칭 토큰의 정상 issuer·다른 issuer·잘못된 서명을 검사했다. 실제 기기의 로그인 호환 확인은 최종 배포 전 필요하다.
- FFprobe와 stdin 디코딩의 프로토콜을 `pipe`, CAF/MP4 임시 파일 디코딩은 `pipe,file`로 제한했다. 허용 컨테이너 목록에서 HLS/concat/DASH/image 입력을 제외했다.
- 합성 서버 파일을 가리키는 HLS 입력은 수정 전에도 거부됐다. **서버 파일 읽기나 SSRF를 재현했다고 해석하지 않는다.**
- Docker 런타임에서 pip와 독립 wheel 패키지를 제거했다. 자체 vendored 의존성의 공격 표면을 줄이며, 실행 중 패키지 설치는 제공하지 않는다. pyworld 0.3.5가 `pkg_resources`를 import하므로 setuptools는 남아 있다.

## 2. 의존성 검사와 남은 출시 차단

공식 Trivy 0.76.1 배포 ZIP의 체크섬을 검증한 뒤 로컬 TAR를 검사했다. 이미지·소스·키는 스캐너 서비스로 업로드하지 않았다. 원시 자료는 `artifacts/security-audit-2026-11-02/`에 있다.

| 검사 | 결과 | 해석 / 제한 |
|---|---|---|
| 새 후보 Debian 13.7 / OS 302개 패키지 | 833개 패키지-공지 행, 고유 CVE 321개. Critical 1 / High 213 / Medium 322 / Low 256 / Unknown 41행 | 같은 FFmpeg CVE가 여러 바이너리 패키지에 반복됨. 833개의 독립 취약점이나 833개 실제 공격 재현을 뜻하지 않음. 스캔에 stable 배포판 수정 버전이 표시된 OS 행은 0개 |
| 새 후보 Trivy Python | 4개 공지: setuptools 79.0.1과 그 내부 jaraco.context 5.3.0 / wheel 0.45.1 | High 2 / Medium 1 / Low 1. 빌드 도구 경로의 경고이며 런타임 도달성은 별도 판단 필요. 제거 전 12행에서 4행으로 감소 |
| pip-audit, 최종 설치 메타데이터 83개 | setuptools 1개 패키지에서 3개 공지 레코드. 동일 PYSEC-2026-3447가 중복되어 고유 공지는 2개 | 초기 82개 `pip freeze` 목록의 0건 결과에는 setuptools/내부 vendored 패키지가 빠져 있었다. 최종 판정에는 이 확대 검사 결과를 사용 |
| pub.dev 잠금 버전 163개 | 해당 버전에 영향 있는 공개 공지 0건, 조회 오류 0건 | 공개 공지 조회이며 Dart/네이티브 소스 전체 감사가 아님 |
| 현재 Git-visible 텍스트 | 715개 파일, 지정 시크릿 패턴 검출 0건 | Git 과거 이력·ignored 자격 증명·바이너리·4MiB 초과 파일 제외. 읽지 못한 15개는 기존 손상 changelog 14개와 비 UTF-8 실험 자료 1개. 미검사 파일을 통과로 세지 않음 |

공개 pub.dev 검사에 포함되지 않는 의존성: 로컬 `audioplayers_windows` 4.3.0, Git `flutter_midi_pro` 3.1.7 (고정 commit `1d8fc682517e3e8398c3aba73abec7d39e5b0e40`). 네이티브/포크 코드 검토는 별도다.

### 반드시 해결하거나 증거로 위험을 배제할 항목

1. **FFmpeg CAF/MACE6 — CVE-2026-66039.** 후보에는 FFmpeg 7.1.5가 있다. Debian tracker는 같은 trixie 패키지를 vulnerable로 표시하며 upstream 7.1.x 수정을 기다리는 상태다. 악성 CAF의 MACE6 decoder 메모리 손상 공지로, CAF는 현재 앱의 허용 형식이다. 이번 정상 CAF 테스트와 프로토콜/컨테이너 제한은 이 코덱 취약점의 해결 증거가 아니다. 악성 파일 실행이나 운영 공격은 시도하지 않았다.
   - 조치: 공식 upstream 수정이 포함된 FFmpeg 빌드를 버전·해시·라이선스와 함께 고정하거나 검증된 패치를 적용한다. 필요한 오디오 코덱만 허용하는 방안도 검증하되 CAF 형식 전체를 막아 iOS 녹음을 깨뜨리지 않는다. 현재 버전을 단순히 최신 stable apt로 재설치하는 것으로 해결됐다고 표시하지 않는다.
2. **libsndfile WAV/IMA ADPCM — CVE-2026-37555.** OS 패키지 외에도 Python soundfile 0.14.0이 실제로 로드하는 `_soundfile_data/libsndfile_x86_64.so`의 버전이 1.2.2임을 확인했다. 공지는 공격자가 조작한 WAV 헤더의 정수 overflow/메모리 손상에 관한 것이다. wheel 내부 바이너리에 해당 패치가 들어 있는지는 증빙하지 못했다. 따라서 OS 패키지만 교체해서 완료 처리할 수 없다.
   - 조치: 실제 로드하는 라이브러리의 upstream 수정 포함 여부를 확인하고, 미포함이면 패치된 바이너리로 고정한다. 헤더 검사 `sf.info`도 같은 라이브러리를 쓰므로 현재 길이 검사만으로 안전하다고 판단하지 않는다. 분석·오토튠 두 입력 경로를 함께 검증한다.
3. **setuptools와 내부 빌드 라이브러리.** 상위 setuptools의 공지는 macOS sdist 파일 제외 규칙과 Windows legacy wheel 설치 경로에 관한 것으로, Linux API의 요청 경로에서 해당 빌드/설치 기능을 사용한다는 근거는 찾지 못했다. 그러나 패키지는 존재하므로 무조건 오탐 처리하지 않는다. 상위 버전으로 무조건 올리면 pyworld의 `pkg_resources` import가 깨질 수 있다.
   - 조치: pyworld의 배포 메타데이터 조회를 지원되는 방식으로 옮기거나 검증된 상위 배포판으로 전환한 뒤 setuptools 및 vendored 빌드 도구를 제거한다. 오토튠 실제 합성 회귀를 다시 확인한다.
4. **나머지 OS 경고 도달성 분류.** Critical 표시는 libxml2 CVE-2026-6653이다. Debian은 trixie에서 no-dsa/minor issue로 분류한다. 스캐너 등급만으로 원격 코드 실행을 주장하거나, Debian의 낮은 우선순위만으로 전체 통과 처리하지 않는다. XML·이미지·영상·네트워크 처리 의존성의 실제 사용 여부와 제거 가능성을 정리해야 한다.

오디오 파서는 고객 업로드를 다루므로 위 1·2는 우선순위가 높다. 장기적으로 디코더가 서버 키·고객 파일에 접근할 수 없는 별도 실행 경계를 두는 것도 필요하다. 이번 `--network none`은 **시험 컨테이너의 조건**이며 실제 운영 디코더가 격리됐다는 뜻이 아니다.

공식 근거:

- [Debian FFmpeg CAF 공지·패치 링크](https://security-tracker.debian.org/tracker/CVE-2026-66039)
- [Debian libsndfile 공지·upstream 수정 링크](https://security-tracker.debian.org/tracker/CVE-2026-37555)
- [Debian libxml2 상태](https://security-tracker.debian.org/tracker/CVE-2026-6653)
- [setuptools sdist 공지](https://github.com/advisories/GHSA-h35f-9h28-mq5c), [legacy wheel 공지](https://github.com/advisories/GHSA-xmj3-9gf7-h52w)
- [Trivy의 내장 SBOM 처리](https://trivy.dev/docs/dev/guide/target/container_image/), [pub.dev 공지 API](https://github.com/dart-lang/pub/blob/main/doc/repository-spec-v2.md)

## 3. 운영 Supabase — 메타데이터 읽기만 수행

프로젝트 `iznehtmmpnivtjdiohgg`의 SQL Editor에서 `begin read only`로 정책·역할 메타데이터만 조회했다. 고객 행·구매 토큰·결제 payload는 읽지 않았다. 정책 변경도 하지 않았다.

| 테이블 | RLS | 실제 정책 | 고객 역할의 RLS 우회 |
|---|---|---|---|
| cloud_projects | 켬 | read_own_cloud_projects / SELECT / auth.uid() = user_id | 없음 |
| cloud_quota | 켬 | read_own_cloud_quota / SELECT / auth.uid() = user_id | 없음 |
| subscriptions | 켬 | subscriptions_self_read / SELECT / user_id = auth.uid() | 없음 |
| iap_notifications | 켬 | 정책 없음: 고객 역할은 기본 거부 | 없음 |

anon/authenticated 모두 superuser=false, bypassrls=false. 네 테이블에 고객 write 정책이 없음을 확인했다. SELECT grant가 있다는 사실만으로 RLS 데이터 노출이라고 판단하지 않는다. 증거: `production-rls-ax.txt`, `production-rls.png`. 전체 schema/RPC/storage/auth 설정을 모두 조사한 결과는 아니다. 이전 migration007 적용 범위는 유지된다.

## 4. 실제 검증과 새 로컬 후보

- 백엔드 전체: **335 통과 / 11 skip**. 기준 325개에 신규 보안 경계 10개 추가. skip은 기존 실제 서비스 테스트이며 성공으로 세지 않는다.
- 새 Linux 후보: 네트워크 차단·1GiB·1CPU·UID1000에서 **17개 통과**. health, 비루트, 런타임 pip/wheel 부재, pyworld 실행, 비밀 파일 부재, 음원 11개, HTTP Range/해시, cloud OFF, WAV/Opus/CAF/M4A의 A4 검출, HLS 거부/오류 원문 미반환, MIDI 파싱을 확인했다.
- 별도 합성 신호로 pyworld의 dio→stonemask→cheaptrick→d4c→synthesize를 실행했고, 유한한 값의 비어 있지 않은 합성 결과를 확인했다(`pyworld-synthesis.json`). 사람의 청취 검증은 아니다.
- 새 후보 태그: `humtrack-backend:qa-20261102-security`.
- 이미지 index digest: `sha256:62157508c5183c1c0228972e1b157ff17482528cecef3c801a0aaf53b2b116f1`.
- TAR: `artifacts/releases/backend-candidate-20261102-security/humtrack-backend-qa-20261102-security.tar`.
- TAR SHA-256: `51e3bc16390dfa38f2e08dd8243bedaf49aeb22c4d9a2682e69659db8f74b680`. OCI index→platform manifest→config/layers 및 archive 해시 검증 완료.
- 빌드 시 현재 backend 파일의 해시를 고정하고 빌드 후 동일함을 확인했다. 현재 미커밋 파일을 포함하므로 Git HEAD만으로 후보를 재현할 수 없다. `backend-build-receipt.json`을 함께 사용한다.
- **이전 `backend-candidate-20261102`에는 이번 보안 수정이 없다.** 이력 보존용이며 새 보안 수정본으로 오인하지 않는다. 새 후보도 위 미해결 경고 때문에 공개 배포 가능 판정은 아니다.

Windows 설치 후보·Android AAB·실제 서비스 설정은 바꾸지 않았다. 앱 소스가 그대로라 Flutter 전체 테스트를 반복하지 않았다.

## 5. 출시 전 남은 보안 확인

우선 위 네이티브 파서·빌드 의존성 항목을 처리한 새 서버 후보에서 동일 회귀와 취약점 검사를 다시 수행한다. 이후 실제 Supabase 로그인 토큰·구매/복원·앱 클라우드 왕복을 최종 후보로 확인한다. 운영 배포와 Git push/PR은 사용자 요청 전까지 보류한다.

추가 점검 범위: 모바일 세션 저장·Android 백업의 자격 증명 제외 여부, Windows/모바일 네이티브 바이너리와 포크, Git 과거 이력의 시크릿, 나머지 API/RPC 권한, IAP 공급자 예외 로그의 토큰 노출 여부. 이 항목들은 이번 제한된 검사에서 안전을 입증하지 않았으며, 확인하지 않은 부분을 취약점 확정으로 기록하지도 않는다.
