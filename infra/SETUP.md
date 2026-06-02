# Humming V2 — 인프라 셋업 가이드 (Tier 0 / MVP)

수동 1회성 셋업. **순차로 진행** — 뒷 단계는 앞 단계에서 받아낸 시크릿을 사용합니다. 총 실작업 시간 약 **3시간** (대부분 대기 시간이며, DNS / 스토어 심사는 며칠 걸릴 수 있음).

스펙 출처: `docs/infra-mvp.html` §1 스택, §5 셋업, §9 Observability.

---

## 0. 사전 준비 (5분)
- Apple Developer 계정 ($99/년) — 이미 결제됨
- Google Play Console ($25 일회성) — 이미 결제됨
- 결제수단 (Cloudflare / Fly.io / Supabase / Vercel 등록용 신용카드)
- CLI 도구 설치:
  ```bash
  brew install flyctl supabase/tap/supabase vercel-cli gh
  npm i -g @cloudflare/wrangler
  ```

---

## 1. Cloudflare — 도메인 + DNS + R2 (30분)

**목표**: 도메인 등록, R2 버킷 생성, DNS 레코드 준비 (api → Fly, apex/www → Vercel).

1. **도메인 등록** — Cloudflare Registrar 에서 등록 (예: `hum-track.com`). 약 10분 전파. 비용 ~$10/년.
2. **DNS 레코드** — `infra/cloudflare/dns.md` 참고. Fly와 Vercel 의 호스트네임이 나온 뒤 추가 (3, 4번 단계 후).
3. **R2 버킷 생성**:
   - 대시보드 → R2 → *Create bucket* → 이름 `humming-vocals` → location *Automatic*.
   - Lifecycle 규칙: `infra/cloudflare/r2-lifecycle.md` 참고 (자동 삭제 없음, multipart abort cleanup 만).
4. **R2 API 토큰**:
   - R2 → *Manage R2 API Tokens* → *Create API token*.
   - 권한: *Object Read & Write*, `humming-vocals` 만 scope.
   - **Access Key ID** + **Secret Access Key** 저장 (한 번만 표시됨).
   - **Account ID** 저장 (R2 대시보드 우측 상단).
5. **Cloudflare DNS Proxy**: `api.` 만 orange-cloud 활성화. **Fly 인증서 발급 완료 후** (3.6 단계).

**받아낼 시크릿**:
- `R2_ACCOUNT_ID`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_BUCKET=humming-vocals`

---

## 2. Vercel — 랜딩 페이지 (10분)

1. `vercel login` (GitHub OAuth 로 로그인).
2. 저장소 루트에서: `cd landing && vercel link` (프로젝트명 `humming-landing`).
3. *Settings → Domains* → `hum-track.com` 와 `www.hum-track.com` 추가.
   Vercel 이 CNAME 대상 (예: `cname.vercel-dns.com`) 을 반환 → Cloudflare DNS 에 추가 (dns.md 참고).
4. *배포*: `vercel deploy --prod` (랜딩 코드가 준비된 뒤 최초 1회).

**받아낼 시크릿**: 없음 (Vercel 이 TLS 자동 처리).

---

## 3. Fly.io — API 서버 (25분)

1. `flyctl auth login` (브라우저에서 로그인).
2. `backend/` 디렉터리에서:
   ```bash
   flyctl launch --no-deploy --copy-config --name humming-api --region iad
   ```
   기존 `fly.toml` 그대로 사용. 아직 **배포는 하지 않음**.
3. **시크릿 설정** (절대 git 에 commit 금지). 1, 4, 5, 6 번 단계에서 받아낸 값 채워넣기:
   ```bash
   flyctl secrets set \
     SUPABASE_URL=... \
     SUPABASE_SERVICE_ROLE_KEY=... \
     SUPABASE_JWT_SECRET=... \
     R2_ACCOUNT_ID=... \
     R2_ACCESS_KEY_ID=... \
     R2_SECRET_ACCESS_KEY=... \
     R2_BUCKET=humming-vocals \
     SENTRY_DSN=... \
     POSTHOG_API_KEY=... \
     APPLE_SHARED_SECRET=... \
     GOOGLE_PLAY_SERVICE_ACCOUNT_JSON='{...}'
   ```
4. **배포**: `flyctl deploy --remote-only`.
5. **커스텀 호스트네임**: `flyctl certs add api.hum-track.com`. CNAME 대상 반환 → Cloudflare DNS 에 추가 (dns.md 참고). `flyctl certs show` 가 *Issued* 상태가 될 때까지 대기 (보통 5분 미만).
6. **Cloudflare proxy 활성화** — `api.` 레코드의 orange cloud 켜기. 재테스트: `curl -fsS https://api.hum-track.com/health`.
7. **지출 알람**: Fly 대시보드 → *Billing* → *Spending alerts* → 임계치 $5/일 → `heobusy@gmail.com`.

---

## 4. Supabase — DB + Auth (40분)

1. 대시보드 → *New project*:
   - 리전: **us-east-1** (Fly iad 와 가장 가까움).
   - DB 비밀번호: 생성 후 1Password 에 저장.
2. **마이그레이션 실행**:
   ```bash
   cd backend
   supabase link --project-ref <ref>
   supabase db push   # migrations/001_initial_schema.sql 적용됨
   ```
3. **인증 provider** — *Authentication → Providers*:
   - **Apple**: 활성화. Apple Developer 에서 Services ID, Team ID, Key ID, p8 private key 필요. Supabase 가 표시하는 redirect URL 을 Apple → Services ID 의 *Return URLs* 에 붙여넣기.
   - **Google**: 활성화. Google Cloud Console *OAuth 2.0 Client IDs* 에서 Web client ID + secret. Supabase redirect URL 을 *Authorized redirect URIs* 에 추가.
   - **Kakao**: 활성화. Kakao Developers → *내 애플리케이션* 에서 REST API 키 + client secret. Supabase redirect URL 을 *플랫폼 → Web* 의 *Redirect URI* 에 추가.
   - **Redirect URL 형식** (Supabase 가 자동 생성): `https://<ref>.supabase.co/auth/v1/callback`
   - **모바일 deep link** (*URL Configuration → Site URL* 에서 설정): `humming://auth/callback`
4. **이메일 템플릿**: 기본값 그대로 (MVP 에서는 magic link 안 씀).
5. **DB 용량 알람**: *Project Settings → Billing → Usage* → 무료 한도 80% (400MB) 도달 시 이메일 활성화.

**받아낼 시크릿**:
- `SUPABASE_URL=https://<ref>.supabase.co`
- `SUPABASE_SERVICE_ROLE_KEY` (*Project Settings → API*)
- `SUPABASE_JWT_SECRET` (*Project Settings → API → JWT Settings*)

---

## 5. Sentry — 에러 + APM (15분)

1. Sentry.io → *Create project* 두 번:
   - `humming-mobile` (플랫폼: Flutter)
   - `humming-server` (플랫폼: Python / FastAPI)
2. 각 프로젝트의 **DSN** 저장.
3. **알람 규칙**: `infra/alerts/sentry-alerts.json` 참고 → Sentry Alerts UI 에서 수동 입력 (무료 플랜은 API 로 규칙 생성 불가, JSON 을 체크리스트로 활용).
4. **샘플링**: 모바일 + 서버 SDK 양쪽에 `traces_sample_rate=0.1` (10%) 설정 → MAU 1k 까지 월 5k 이벤트 한도 안에서 운영.

**받아낼 시크릿**:
- `SENTRY_DSN` (server) → Fly secrets 에 등록
- 모바일 DSN → Flutter `--dart-define` 에 주입

---

## 6. PostHog — 분석 (10분)

1. PostHog Cloud 가입 (US 리전, 무료 plan).
2. *Project Settings → Project API Key* → 복사.
3. funnel 설정: 가입 → 첫 곡 → 내보내기 → 구독 (대시보드에서 수동).

**받아낼 시크릿**:
- `POSTHOG_API_KEY` → Fly secrets + Flutter `--dart-define`
- 호스트: `https://us.posthog.com`

---

## 7. UptimeRobot — 가용성 모니터링 (5분)

1. 무료 계정 생성.
2. *Add Monitor* → HTTP(s) → `https://api.hum-track.com/health` → 5분 간격.
3. *Alert contacts*: `heobusy@gmail.com` + iOS 푸시 (UptimeRobot 앱 설치).
4. 모니터 목록 및 에스컬레이션 정책은 `infra/alerts/uptimerobot.md` 참고.

---

## 8. App Store Connect — IAP (30분 + 24~48시간 심사)

1. *My Apps → Humming → In-App Purchases → Manage*:
   - 자동 갱신 구독 그룹: `humming_pro`
   - 상품 ID:
     - `humming_pro_monthly` — $4.99/월, 7일 무료 체험 (Introductory Offer)
     - `humming_pro_yearly`  — $39.99/년, 7일 무료 체험
2. *App Information → App-Specific Shared Secret* → 생성 → `APPLE_SHARED_SECRET` 으로 복사.
3. *Users and Access → Keys → In-App Purchase* → 키 생성, `.p8` 다운로드. Key ID + Issuer ID 메모 (App Store Server API 용).
4. 첫 빌드와 함께 상품 심사 제출.

**받아낼 시크릿**:
- `APPLE_SHARED_SECRET`
- App Store Server API 키 (p8) — 서버-서버 검증 도입 시 (post-MVP) Fly multi-line secret 으로 저장.

---

## 9. Play Console — IAP (30분 + 24시간 심사)

1. *Monetize → Products → Subscriptions*:
   - `humming_pro_monthly` — $4.99/월, 7일 무료 체험.
   - `humming_pro_yearly`  — $39.99/년, 7일 무료 체험.
2. *Monetization setup → Real-time developer notifications*:
   - Google Cloud Pub/Sub 토픽 `humming-rtdn` 생성.
   - 토픽명을 Play Console 에 붙여넣기.
3. *Setup → API access*:
   - Google Cloud 프로젝트 연결.
   - 서비스 계정 `humming-play-api` 생성, 역할 *Pub/Sub Subscriber* + *Android Publisher* (Play Console linkage 경유).
   - JSON 키 다운로드 → `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` Fly secret 으로 저장.

**받아낼 시크릿**:
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` (전체 JSON inline)

---

## 시간 요약

| 단계 | 실작업 시간 |
|------|-----------|
| 0 사전준비 | 5분 |
| 1 Cloudflare | 30분 |
| 2 Vercel | 10분 |
| 3 Fly.io | 25분 |
| 4 Supabase | 40분 |
| 5 Sentry | 15분 |
| 6 PostHog | 10분 |
| 7 UptimeRobot | 5분 |
| 8 App Store IAP | 30분 (+24~48시간 심사) |
| 9 Play IAP | 30분 (+24시간 심사) |
| **총 실작업** | **≈ 3시간 20분** |

---

## 검증 체크리스트

- [ ] `curl https://api.hum-track.com/health` → `{"status":"ok"}`
- [ ] Cloudflare proxy `api.` 활성화 (orange cloud)
- [ ] `flyctl secrets list` 에 11개 시크릿 표시
- [ ] `supabase db push` 성공, `projects` `tracks` `chunks` `notes` `subscriptions` 테이블 존재
- [ ] Sentry 테스트 이벤트 (서버 `/health` 에 `raise` 추가) 30초 안에 표시
- [ ] PostHog Live Events 에 Vercel 랜딩의 `$pageview` 표시
- [ ] UptimeRobot 모니터 그린 상태
- [ ] IAP 상품 "Ready to Submit" 또는 "Approved" 상태
- [ ] Fly 지출 알람 $5/일 설정 완료
- [ ] Supabase 사용량 알람 80% 설정 완료
