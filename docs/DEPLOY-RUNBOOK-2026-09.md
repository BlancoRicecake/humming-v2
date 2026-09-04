# 배포 런북 — 2026-09 재개 작업분

> 대상: 2026-09-03~04 에 작업한 커밋 전체 (백엔드 보안·운영, 모바일 결제·코어·오디오, 랜딩, 약관).
> 원칙: **백엔드 먼저, 앱 나중.** 새 앱은 새 백엔드를 요구하지만, 새 백엔드는 구 앱과 호환된다.
> 소요: 백엔드 30분 + 관측 1일 → 앱 빌드·심사 (Mac 작업은 [MAC-WORKORDER-2026-09.md](MAC-WORKORDER-2026-09.md)).

---

## 0. 왜 급한가

지금 프로덕션에 살아 있는 취약점:

| | 내용 |
|---|---|
| **위조 영수증** | Apple 영수증 서명을 *요청자가 보낸 인증서*로 검증 → 자체 서명한 가짜 영수증으로 누구나 Pro 획득 가능 |
| **인증 우회** | `SUPABASE_JWT_SECRET` 미설정 시 HS256 토큰을 서명 검증 없이 수락 → 타인 계정으로 API 호출 가능 (현재 설정 여부는 1-1 에서 확인) |
| **구독 만료 미반영** | 해지·환불·만료 웹훅이 유저를 찾지 못해 폐기됨 → 해지한 사용자가 계속 Pro |

---

## 1. 사전 점검 (10분, 배포 전 필수)

### 1-1. Fly 시크릿 확인 ⚠️ 가장 중요

```bash
fly secrets list -a humming-api
```

**`SUPABASE_JWT_SECRET` 이 목록에 있어야 한다.** JWT 검증이 fail-closed 로 바뀌었기 때문에, 없으면 로그인 사용자의 모든 요청이 503 이 되고 **유료 사용자 전원이 Pro 를 잃는다.**

- 있으면 → 통과.
- 없으면 → Supabase 대시보드 *Project Settings → API → JWT Settings* 에서 복사해 등록:
  ```bash
  fly secrets set SUPABASE_JWT_SECRET='...' -a humming-api
  ```
- 프로젝트가 비대칭 키(ES256/RS256)만 발급한다면 JWKS 로 검증되므로 없어도 된다. 판별법: 앱에서 로그인한 뒤 토큰을 하나 떠서 헤더의 `alg` 를 본다. `HS256` 이면 시크릿 필수.

이어서 나머지도 확인:

```bash
fly secrets list -a humming-api | grep -E "SUPABASE_SERVICE_ROLE_KEY|APPLE_BUNDLE_ID|GOOGLE_PACKAGE_NAME|IAP_WEBHOOK_SECRET|GOOGLE_PUBSUB_AUDIENCE"
```

| 시크릿 | 없으면 |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | `/iap/*`, `/projects`, `/account` 전부 503 |
| `IAP_WEBHOOK_SECRET` 또는 `GOOGLE_PUBSUB_AUDIENCE` | Google 웹훅이 403 (fail-closed) → Play 해지·갱신 미반영 |
| `APPLE_BUNDLE_ID` | Apple 영수증의 bundleId 검증을 건너뜀 (경고만) |
| `GOOGLE_PACKAGE_NAME` | Play 영수증 검증 503 |

`IAP_WEBHOOK_SECRET` 이 없으면 지금 만든다 (2-3 에서 Pub/Sub URL 에 붙인다):

```bash
SECRET=$(openssl rand -hex 24); echo "$SECRET"   # 메모해 둘 것
fly secrets set IAP_WEBHOOK_SECRET="$SECRET" -a humming-api
```

### 1-2. 로컬 테스트 통과 확인

```bash
cd backend
./.venv/Scripts/python -m pytest tests -q      # Windows
# 기대: 152 passed, 1 failed, 11 skipped
```

실패 1건은 `test_autotune.py::test_endpoint_undecodable_upload_is_400` — 로컬에 ffmpeg 가 없어서 나는 환경 문제이며 서버에는 ffmpeg 가 있다. CI(2026-09 추가)에서는 ffmpeg 를 설치하므로 통과해야 정상.

### 1-3. 현재 상태 백업

```bash
fly releases -a humming-api | head -3     # 롤백 대상 버전 메모
```

Supabase 대시보드 → *Database → Backups* 에서 최신 백업 시각 확인 (마이그레이션 전 스냅샷이 있어야 함).

---

## 2. 백엔드 배포

### 2-1. DB 마이그레이션 (반드시 코드 배포보다 먼저)

```bash
cd backend
supabase link --project-ref <ref>       # 이미 링크돼 있으면 생략
supabase db push                         # migrations/002_iap_transaction_binding.sql 적용
```

또는 Supabase 대시보드 SQL 편집기에 `backend/migrations/002_iap_transaction_binding.sql` 내용을 붙여넣어 실행.

적용 확인:

```sql
select column_name from information_schema.columns
 where table_name = 'subscriptions'
   and column_name in ('original_transaction_id','purchase_token','environment','last_event_at','transaction_id');
-- 5행이 나와야 한다
```

> 순서가 바뀌어도 결제가 죽지는 않는다 — 백엔드가 컬럼 부재를 감지해 구 스키마로 저장하고 로그에 ERROR 를 남긴다. 다만 그 동안 웹훅 유저 매핑이 동작하지 않으므로, 마이그레이션을 먼저 하는 것이 정상 경로다.

### 2-2. 코드 배포

```bash
cd backend
fly deploy --remote-only --build-arg GIT_SHA=$(git rev-parse --short HEAD)
```

빌드 컨텍스트에 `models/` (3.2MB, git 추적됨) 와 `soundfonts/*.sf2` (gitignore 됨, 로컬에만 존재) 가 필요하다. 로컬 체크아웃에서 배포할 것.

### 2-3. 스토어 웹훅 등록

**Apple** — App Store Connect → *App Information → App Store Server Notifications*:
- Production URL: `https://api.hum-track.com/iap/webhook/apple`
- Sandbox URL: 동일
- Version: **Version 2**

**Google** — Google Cloud Console → Pub/Sub → 토픽 `humming-rtdn` → push 구독:
- Endpoint: `https://api.hum-track.com/iap/webhook/google?token=<IAP_WEBHOOK_SECRET>`
- 토큰이 없거나 틀리면 403 이 되고 Pub/Sub 가 재시도한다.

---

## 3. 배포 검증 (배포 직후 5분)

### 3-1. 부팅 로그

```bash
fly logs -a humming-api | head -60
```

**ERROR 줄이 하나도 없어야 한다.** 나올 수 있는 것들:

| 로그 | 의미 | 조치 |
|---|---|---|
| `AUTH DISABLED: neither SUPABASE_URL ...` | 🚨 로그인 전면 실패 | 즉시 1-1 로 |
| `SUPABASE_SERVICE_ROLE_KEY unset` | 🚨 결제·계정 API 503 | 즉시 1-1 로 |
| `Google RTDN webhook is unauthenticated and therefore BLOCKED` | Play 해지 미반영 | 1-1 의 시크릿 등록 |
| `learned model ...: loaded` ×3 | ✅ 정상 | — |
| `learned model ...: MISSING` | 이미지에 `models/` 누락 | 로컬 체크아웃에서 재배포 |
| `environment='dev' (not production)` | fly.toml 의 ENV 미적용 | fly.toml `[env] ENV="production"` 확인 |

### 3-2. 엔드포인트

```bash
curl -fsS https://api.hum-track.com/health && echo OK

# 인증 확인 — 앱에서 얻은 실제 액세스 토큰으로
TOKEN='eyJ...'
curl -s https://api.hum-track.com/iap/status -H "Authorization: Bearer $TOKEN" | jq
# 기대: {"pro": true/false, "status": ..., "server_time": ...}
# 401/503 이면 1-1 의 JWT 시크릿 문제
```

### 3-3. 구 앱 호환성 (중요)

**스토어에 올라가 있는 1.0.5 앱이 계속 동작해야 한다.** 구 앱은 `/iap/status` 를 모르고 Supabase 의 `subscriptions` 행을 직접 읽으므로, 상태 문자열이 그대로면 영향이 없다. 배포 후 30분간:

```bash
fly logs -a humming-api | grep -E "iap verify|500|503" | head -20
```

`/iap/verify` 가 400 을 많이 뱉으면 구 앱의 영수증이 새 검증에 걸리는 것이므로 즉시 롤백(4번).

---

## 4. 롤백

```bash
fly releases -a humming-api                 # 이전 버전 번호 확인
fly deploy --image <이전 이미지> -a humming-api
# 또는
fly releases rollback <version> -a humming-api
```

마이그레이션 002 는 **컬럼 추가뿐이므로 롤백 불필요** (구 코드는 새 컬럼을 무시한다). 되돌릴 필요 없음.

---

## 5. 관측 (배포 후 24~48시간)

| 볼 것 | 어디서 | 정상 |
|---|---|---|
| 5xx 비율 | Sentry `humming-server` | 배포 전과 동일 |
| `/iap/verify` 400 급증 | Fly 로그 | 없음 |
| 웹훅 수신 | `select count(*) from iap_notifications where received_at > now() - interval '1 day'` | 0보다 큼 |
| 웹훅 매핑 실패 | `select count(*) from iap_notifications where error = 'no_user'` | 앱 업데이트 전까지는 존재하는 게 정상 |
| 구독 상태 | `select status, count(*) from subscriptions group by 1` | expired 가 갑자기 폭증하지 않을 것 |
| 가용성 | UptimeRobot | 다운 없음 |

### 5-1. 정합성 점검 (앱 배포 후 1주일 뒤 권장)

구 앱 사용자는 거래 ID 바인딩이 없어 웹훅이 유저를 못 찾는다. 이 구간을 메운다:

```bash
cd backend
python tools/reconcile_subscriptions.py               # dry run — 차이만 출력
python tools/reconcile_subscriptions.py --apply       # 반영
```

주 1회 정기 실행을 권장한다 (infra/SETUP.md §10).

---

## 6. 앱 배포

Mac 에서 진행 → **[MAC-WORKORDER-2026-09.md](MAC-WORKORDER-2026-09.md)** 에 복붙 가능한 순서로 정리돼 있다.

앱 배포 전 반드시 백엔드가 먼저 올라가 있어야 한다. 새 앱은 `/iap/status` 를 호출하며, 이 엔드포인트가 없으면 (404) 캐시된 판정으로 폴백하다가 결국 Pro 를 잃는다.

---

## 7. 약관 개정 고지 (앱 배포와 함께)

`docs/legal/` 의 약관·개인정보처리방침·환불정책이 개정되었다 (미구현이던 클라우드 동기화 조항 삭제, 시행일 **2026-10-06**).

약관 제3조에 따라 **시행일 30일 전부터** 앱 내 공지 + 가입 이메일 고지가 필요하다:

- [ ] 랜딩(`landing/{terms,privacy,refund}`) 배포 — Vercel 자동 배포 (main push 시)
- [ ] 앱 내 공지 — 새 빌드에 개정 문서가 포함되므로 앱 업데이트 자체가 고지 수단이 되나, 별도 안내 배너/공지가 있으면 더 안전
- [ ] 가입 이메일 발송 (Supabase Auth 의 사용자 목록 기준)
- [ ] 시행일(2026-10-06) 도달 확인

---

## 체크리스트 (인쇄용)

```
[ ] 1-1  fly secrets list — SUPABASE_JWT_SECRET 확인 (없으면 등록)
[ ] 1-1  IAP_WEBHOOK_SECRET 생성/등록
[ ] 1-2  로컬 pytest 152 통과
[ ] 1-3  Fly 현재 릴리스 번호 메모 + Supabase 백업 확인
[ ] 2-1  supabase db push (002 마이그레이션) + 컬럼 5개 확인
[ ] 2-2  fly deploy --remote-only
[ ] 2-3  Apple Server Notifications V2 URL 등록
[ ] 2-3  Google Pub/Sub push URL(+token) 등록
[ ] 3-1  부팅 로그에 ERROR 없음 / learned model loaded ×3
[ ] 3-2  /health 200, /iap/status 200
[ ] 3-3  30분간 구 앱 호환 확인 (verify 400 급증 없음)
[ ] 5    24~48시간 Sentry·웹훅·구독 상태 관측
[ ] 6    Mac 작업지시서로 앱 빌드 → TestFlight → 심사
[ ] 7    약관 개정 고지 발송
[ ] 5-1  1주일 뒤 reconcile_subscriptions.py 실행
```
