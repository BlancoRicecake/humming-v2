# HumTrack 개인정보처리방침 (Privacy Policy)

<!-- 운영자 필독 (시행 전 조치): 아래 시행일 2026-10-06 은 이용약관 제3조 제3항의
     "회원에게 불리한 변경 또는 중대한 변경의 경우 30일 전 고지" 를 보수적으로 적용한 날짜입니다.
     ⚠ 이번 개정에는 **개인정보처리방침 개정**(세션 리플레이·오류 리포팅 등 분석 도구 고지 정정)이
     포함됩니다. 세션 리플레이는 신규 고지 항목이므로 개인정보처리방침 제10조의 30일 사전 고지
     대상이며, 고지를 생략하거나 기간을 단축할 수 없습니다.
     본 개정본을 배포·게시할 때 시행일 30일 전까지 반드시 다음 두 가지를 모두 이행해야 합니다:
       (1) 앱 내 공지 게시,  (2) 등록 회원 이메일 발송.
     Operator: this revision includes a PRIVACY amendment (session replay and error-reporting
     disclosure), so notice cannot be skipped or shortened. In-app notice AND email to
     registered members must go out at least 30 days before the effective date (2026-10-06). -->
**시행일**: 2026-10-06
**최종개정**: 2026-09-04
**상태**: 1.3-draft — 사업자 정보 + 정책 사실관계 확정. 변호사 자문 권장 5건은 출시 후 진행 가능.

본 방침은 한국어 본문과 영문 본문(English below)을 함께 제공하며, 두 언어 본문은 동등하게 유효합니다.

---

## TL;DR — 한 줄 요약

- **당신의 보컬 녹음은 광고나 AI 학습에 절대 사용되지 않습니다.**
- 보컬은 무료·Pro 구분 없이 분석 서버 메모리에서 처리된 후 **즉시 폐기**됩니다 (디스크에 기록 ❌).
- **곡·보컬·MIDI 등 작업물은 회원의 기기에만 저장됩니다** — 클라우드에 업로드하거나 보관하지 않습니다. 회사가 보유하는 것은 계정 정보와 구독 기록뿐입니다.
- 결제 카드 정보는 Apple / Google 만 보유하며, 우리는 영수증 ID 외 카드 정보에 접근할 수 없습니다.
- 광고 추적 / ATT 권한 / 위치 / 연락처 / 사진 접근 ❌ — 마이크만 사용합니다.
- 데이터 열람·수정·삭제·이전 요청은 언제든 가능합니다 → `heobusy@gmail.com`

---

## 한국어 본문

### 1. 개인정보 처리자
- **개인정보 처리자(Controller)**: 에르모세아르 (대표: 김동현)
- **연락처**: heobusy@gmail.com
- **사업장 주소**: 경기도 용인시 기흥구 공세로 150-29, B01-G160호
- **사업자등록번호**: 106-16-34319

### 2. 처리 항목 및 수집 방법

| 항목 | 수집 시점 | 처리 위치 | 보유 기간 | 법적 근거 |
|---|---|---|---|---|
| 이메일, OAuth provider, OAuth sub | 회원가입 시 | Supabase Auth (us-east-1) | 회원 탈퇴 시까지 | 계약 이행 |
| Apple "Hide my email" relay 주소 | 회원가입 시 (해당 경우) | Supabase Auth | 회원 탈퇴 또는 Apple revoke 시까지 | 계약 이행 |
| 가입일 | 회원가입 시 | Supabase Postgres | 회원 탈퇴 시까지 | 계약 이행 |
| 보컬 음성 녹음 (Opus 16kHz mono, .caf/.ogg) — 분석·보컬 처리·오토튠·이펙트용 | 분석 / 보컬 처리 / 오토튠 / 이펙트 실행 시 | Fly.io iad 서버 메모리 | **처리 완료 즉시 폐기 (저장 ❌)** | 계약 이행 |
| 구독 정보 (스토어, 상품 ID, 구독 상태, 만료일, 스토어 거래 ID) | 결제·갱신·복원 시 | Supabase Postgres (us-east-1) | 회원 탈퇴 시까지 | 계약 이행 |
| IAP 영수증 / 결제 webhook 알림 | 결제·갱신 시 | Supabase Postgres | 90일 (webhook 로그) / 5년 (영수증, 세법) | 법령 의무 |
| 사용 통계 (분석 호출 횟수 — 레이트리밋·남용 방지) | 기능 사용 시 | Supabase Postgres | 회원 탈퇴 시까지 | 계약 이행 |
| 디바이스 모델, OS 버전, 앱 버전 | API 호출 시 | Supabase Postgres / 서버 로그 | 90일 | 정당한 이익 (보안·호환성) |
| 에러·크래시 스택 트레이스 (PII 자동 수집 비활성) | 앱·백엔드 오류 발생 시 | Sentry (미국) | 90일 | 정당한 이익 (안정성) |
| 화면 상호작용 (탭·스크롤 등 세션 리플레이·히트맵, PII 자동 마스킹) | 앱 사용 시 | Microsoft Clarity (미국/글로벌) | 세션 녹화 90일 | 정당한 이익 (제품·UX 개선) |

**중요 (수집하지 않는 항목)**:
- 회원의 곡·보컬·MIDI 등 작업물의 서버 보관 ❌ — 기기에만 저장되며 업로드되지 않습니다 (분석·처리를 위해 전송된 오디오는 메모리에서 처리 후 즉시 폐기)
- 결제 카드 번호 직접 처리 ❌ (Apple / Google 이 처리)
- 위치 정보 ❌
- 연락처 ❌
- 사진 라이브러리 접근 ❌
- 광고 추적 식별자 (IDFA, AAID) ❌ — iOS ATT 권한도 요청하지 않습니다.

**분석·진단 도구 안내**: 위 표의 Sentry(오류·크래시 리포팅)와 Microsoft Clarity(세션 리플레이·히트맵)는 **현재 모두 활성화되어 있습니다**. 새로운 수탁자를 추가하거나 처리 목적을 변경하는 경우 시행일 30일 전 본 방침을 개정하여 사전 고지합니다.

**Sentry (오류·크래시 리포팅)**: 앱과 백엔드에서 발생한 오류·크래시의 스택 트레이스와 발생 환경(기기 모델, OS·앱 버전, 요청 경로)을 수집하며, 성능 트레이싱은 10% 표본만 수집합니다. 서버는 `send_default_pii=False`, 앱은 `sendDefaultPii = false` 로 설정되어 이메일·IP 등 개인정보를 자동 수집하지 않으며, 로그인 사용자는 **Supabase 사용자 ID(불투명 UUID)** 로만 식별합니다. 보컬 오디오·곡·MIDI 는 Sentry 로 전송되지 않습니다.

**Microsoft Clarity (세션 리플레이·히트맵)**: 익명 행동 분석 도구로, 화면 녹화 영상이나 키 입력 원문을 저장하지 않으며 입력 필드 등 민감 영역은 SDK 가 자동 마스킹합니다. 광고 목적으로 사용되지 않고 제3자에 데이터를 이전하지 않으며, IDFA/ATT 추적 식별자도 사용하지 않습니다. 로그인 사용자의 경우 세션을 식별·필터링하기 위해 **Supabase 사용자 ID(불투명 UUID)** 가 Clarity 로 함께 전달됩니다(개인을 직접 식별하는 PII 아님). (IP 로부터 도시 단위의 대략적 위치가 추정될 수 있으나 개인과 연결되지 않습니다.)

### 3. 처리 목적
1. 서비스 제공: 계정 인증, 보컬 분석 및 처리 (오토튠·이펙트 포함)
2. 결제 및 구독 관리: IAP 영수증 검증, 갱신 webhook 처리, Pro 자격 판정
3. 안정성 개선: 오류·크래시 추적 (Sentry — PII 자동 수집 비활성)
4. 제품·UX 개선: 익명 세션 리플레이·히트맵 분석 (Microsoft Clarity)
5. 보안: 이상 접속 탐지, API rate limiting
6. 법령상 의무: 세법, 전자상거래법, 전자금융거래법

### 4. 보유 및 파기
1. **회원 탈퇴 시**: Supabase Auth 의 계정 정보, Supabase Postgres 의 구독·영수증 기록, 그리고 Cloudflare R2 에 해당 회원 prefix 로 남아 있는 객체가 있는 경우 이를 포함하여 **72시간 이내 cascade 영구 삭제**합니다 (SLA: 영업일 기준 3일 이내 접수 확인).
2. **회원의 작업물**: 곡·보컬·MIDI 등 작업물은 **회원의 기기에만 저장**되며 회사 서버에 보관되지 않습니다. 따라서 회사는 이를 열람·삭제·복구할 수 없으며, 삭제·백업은 회원이 기기에서 직접 수행합니다.
3. **Pro 구독 만료 시**: Pro 전용 기능(곡 무제한 저장, WAV/MIDI/스템 내보내기)만 잠기며, **이미 기기에 저장된 곡은 삭제되지 않고 그대로 열람·편집·재생할 수 있습니다.** 별도의 휴면 계정 정책이 향후 도입될 경우 시행일 30일 전 본 방침 개정을 통해 사전 고지합니다.
4. **IAP 영수증**: 「전자상거래법」 및 「전자금융거래법」 상 보존 의무에 따라 결제·계약 기록은 5년 보관.
5. **IAP webhook 알림 로그**: 90일.
6. **보컬 오디오 (무료·Pro 공통)**: 분석·보컬 처리·오토튠·이펙트 서버 메모리에서 처리 후 즉시 폐기 (영구 저장 ❌).

### 5. 처리 위탁 (Subprocessors)

| 수탁자 | 위탁 업무 | 리전 | 데이터 |
|---|---|---|---|
| Supabase Inc. | DB·인증 호스팅 | 미국 (AWS us-east-1) | 계정, 구독·영수증 기록 |
| Cloudflare, Inc. | DNS·CDN, 객체 스토리지 (R2) | 미국 (us-east-1) | 없음 — 현재 앱은 회원 콘텐츠를 R2 에 업로드하지 않습니다 |
| Fly.io, Inc. | 백엔드 분석·오디오 처리 서버 호스팅 | 미국 (iad — Ashburn, VA) | 보컬 (메모리 처리, 즉시 폐기) |
| Apple Inc. | iOS IAP 처리, Apple Sign In | 미국 | 영수증, OAuth sub |
| Google LLC | Android IAP 처리, Google Sign In | 미국 | 영수증, OAuth sub |
| Functional Software, Inc. (Sentry) | 오류·크래시 리포팅 | 미국 | 에러 stack trace, 사용자 ID(불투명 UUID) |
| Microsoft Corporation (Clarity) | 세션 리플레이·히트맵 (익명 행동 분석) | 미국 / 글로벌 | 화면 상호작용 이벤트 (PII 마스킹) |

EU/EEA 거주자의 개인정보가 한국 또는 미국으로 이전되는 경우, **유럽위원회 표준계약조항(SCC, 2021/914/EU)** 또는 동등한 보호 장치를 통해 보호됩니다.

### 6. 이용자 권리

회원은 다음 권리를 보유하며, `heobusy@gmail.com` 또는 앱 내 "설정 → 계정 삭제"를 통해 행사할 수 있습니다:

- **(한국 PIPA)** 개인정보 열람·정정·삭제·처리정지·동의 철회 요구권
- **(GDPR, EU/EEA/UK)** 열람, 정정, 삭제, 처리 제한, 데이터 이동성, 처리 이의권, 감독기구 진정권 (예: 독일 BfDI, 프랑스 CNIL, 아일랜드 DPC). 자동화된 의사결정 거부권 — **본 서비스는 법적 효력이 있는 자동화된 결정을 수행하지 않습니다.**
- **(CCPA/CPRA, California)** 알 권리(Right to Know), 삭제 요구권, 정정 요구권, 판매/공유 거부권(Opt-out of Sale/Share), 민감 개인정보 처리 제한 요구권, 비차별 권리.

**핵심 명시 (CCPA)**: **회사는 개인정보를 판매하거나 cross-context behavioral advertising 목적으로 제3자와 공유하지 않습니다.** 지난 12개월간 판매된 항목 = **없음**.

**데이터 이동성**: Pro 회원은 앱 내에서 자신의 MIDI/WAV 작업물을 직접 export 할 수 있습니다. 추가로 백엔드 보유 본인 데이터의 일괄 조회·다운로드는 향후 P1 로 UI 구현 예정이며, 현재는 이메일 요청 시 제공합니다.

**SLA**: 모든 권리 행사 요청은 영업일 기준 3일 이내 접수 확인, **데이터 삭제는 72시간 이내** 완료합니다. 기타 요청(열람·정정 등)은 GDPR 기준 1개월 이내(복잡한 경우 2개월 연장 가능) 처리합니다.

### 7. 보안 조치
- **전송 구간**: TLS 1.3 암호화
- **저장 구간**: Supabase 저장 데이터 암호화 (계정·구독·영수증 기록). 회원 작업물은 서버에 저장되지 않으며 기기 내 OS 보호를 따릅니다.
- **접근 통제**: Supabase Row-Level Security (사용자별 데이터 격리), 백엔드 API JWT 검증
- **인증**: OAuth via Apple / Google (회사가 비밀번호를 직접 저장 ❌)
- **PII 최소화**: Sentry 는 PII 자동 수집을 비활성(`send_default_pii=false`)하고 로그인 사용자를 Supabase 사용자 ID(불투명 UUID)로만 식별합니다. Microsoft Clarity 는 입력 필드 등 민감 영역을 SDK 가 자동 마스킹합니다.

회사는 소규모 운영 단계로, ISO 27001 등 공식 인증은 보유하지 않습니다. 인증 획득 시 본 방침에 반영합니다.

### 8. 만 14세 미만 아동
회사는 만 14세 미만(한국 PIPA 기준) 및 만 13세 미만(미국 COPPA 기준) 아동의 개인정보를 의도적으로 수집하지 않습니다. 보호자가 자녀의 무단 사용·계정을 발견한 경우 위 이메일로 통보 시 즉시 삭제 처리합니다. App Store / Google Play 의 앱 등급은 4+ 또는 12+ 로 설정되어 13세 미만 다운로드를 제한합니다.

### 9. 개인정보보호 책임자
- **책임자**: 김동현 (대표)
- **이메일**: heobusy@gmail.com
- **EU 대리인 (GDPR Art. 27)**: 현재 별도 지정하지 않습니다. EU 사용자는 GDPR 상의 모든 권리 (열람·정정·삭제·이동성·이의·진정 등) 를 위 이메일을 통해 행사하실 수 있으며, 회사가 직접 응답합니다. 향후 EU 사용자 비중이 의미있는 수준으로 증가할 경우 EU 내 대리인을 지정하고 본 방침 개정을 통해 사전 고지합니다.

EU 거주자는 본 처리방침의 권리 행사가 충분치 않다고 판단될 경우 거주국 데이터보호감독기구에 진정을 제기할 권리를 가집니다.

### 10. 변경 고지
본 방침은 법령·서비스 변경에 따라 개정될 수 있습니다. **중대한 변경(처리 항목·목적·보유 기간·수탁자 추가 등)은 시행일 30일 전** 앱 내 공지 및 가입 이메일로 고지합니다. 사소한 변경(오탈자, 문구 명확화)은 본 페이지 상단 "최종개정" 일자로 안내합니다.

---

## English Version

### 1. Controller
- **Data Controller**: Hermosear (Representative: Kim Dong Hyun)
- **Contact**: heobusy@gmail.com
- **Address**: 150-29 Gongse-ro, Giheung-gu, Yongin-si, Gyeonggi-do, Republic of Korea (B01-G160)
- **Business Registration**: 106-16-34319

### 2. Data We Collect

| Data | When | Where | Retention | Legal Basis |
|---|---|---|---|---|
| Email, OAuth provider/sub | Sign-up | Supabase Auth (us-east-1) | Until account deletion | Contract |
| Apple relay email (if used) | Sign-up | Supabase Auth | Until deletion or Apple revoke | Contract |
| Vocal audio (Opus 16 kHz mono) — analysis, vocal processing, autotune, effects | Analyze / process / autotune / effects action | Fly.io iad server memory | **Discarded immediately; never written to disk** | Contract |
| Subscription record (store, product ID, status, expiry, store transaction ID) | Purchase / renewal / restore | Supabase Postgres (us-east-1) | Until account deletion | Contract |
| IAP receipts / billing webhook notifications | Purchase/renewal | Supabase Postgres | 90 days webhook log; 5 years receipts (tax) | Legal obligation |
| Usage counters (analysis calls, for rate limiting) | Feature use | Supabase Postgres | Until deletion | Contract |
| Device model, OS / app version | API call | Supabase Postgres / logs | 90 days | Legitimate interest |
| Error and crash stack traces (default PII collection off) | App or backend error | Sentry (US) | 90 days | Legitimate interest |
| Screen interactions (taps/scrolls — session replay & heatmaps, PII auto-masked) | Use | Microsoft Clarity (US/global) | 90-day session recordings | Legitimate interest |

**We do NOT collect**: your songs, vocals or MIDI (they stay on your device and are never uploaded for storage — audio you send for analysis or processing is handled in memory and discarded); payment card numbers (Apple/Google handle); location; contacts; photo library; ad identifiers (IDFA/AAID — we never request iOS ATT permission).

**Analytics and diagnostics**: Sentry (error and crash reporting) and Microsoft Clarity (session replay and heatmaps) listed above are **both active today**. If we add a subprocessor or change a processing purpose, we will amend this policy with 30 days' notice before the effective date.

**Sentry** (error and crash reporting) collects stack traces and the surrounding context (device model, OS/app version, request path) from both the app and the backend, plus a 10% sample of performance traces. The server runs with `send_default_pii=False` and the app with `sendDefaultPii = false`, so email and IP are not collected automatically; a signed-in user is identified only by their **Supabase user ID (an opaque UUID)**. Your vocals, songs and MIDI are never sent to Sentry.

**Microsoft Clarity** (session replay & heatmaps) is anonymous behavior analytics: it does not store raw screen recordings or keystrokes, auto-masks sensitive fields, is never used for advertising, transfers no data to third parties, and uses no ad/ATT identifiers. For signed-in users, your **Supabase user ID (an opaque UUID, not directly identifying PII)** is passed to Clarity to filter session replays by user. Approximate city-level location may be inferred from IP but is not linked to identity.

### 3. Purposes
Service operation, payment management, security, stability analytics (Sentry), product/UX analytics (Microsoft Clarity), legal compliance (Korean tax law and Electronic Commerce Act).

**We never use vocal recordings, analysis results, or generated music for advertising, AI/ML training, third-party resale, or our own marketing without your explicit consent.**

### 4. Retention and Deletion
- **Vocal audio (Free and Pro alike)**: discarded immediately after analysis or processing (memory only, never on disk).
- **Your work**: songs, vocals, MIDI and project metadata are stored **only on your device** and are never uploaded to our servers. We therefore cannot read, delete or restore them; deletion and backup happen on your device.
- **When Pro expires**: only the Pro-only features (unlimited saved songs, WAV/MIDI/stem export) lock. **Songs already saved on your device are not deleted** and remain viewable, editable and playable. A future dormant-account policy may be introduced with 30 days' prior notice.
- **Account deletion request**: cascade delete of your Supabase Auth account, your Supabase Postgres subscription and receipt rows, and any objects remaining under your prefix in Cloudflare R2, within **72 hours**, with confirmation in 3 business days.
- **IAP receipts**: retained 5 years per Korean Electronic Commerce Act / Electronic Financial Transactions Act.
- **Webhook logs**: 90 days.

### 5. Subprocessors

| Subprocessor | Purpose | Region |
|---|---|---|
| Supabase, Inc. | DB and auth hosting (account, subscription and receipt records) | US (AWS us-east-1) |
| Cloudflare, Inc. | DNS/CDN and R2 object storage (no member content is currently uploaded to R2) | US (us-east-1) |
| Fly.io, Inc. | Backend analysis and audio processing (in memory) | US (iad, Ashburn VA) |
| Apple Inc. | iOS IAP, Sign In with Apple | US |
| Google LLC | Android IAP, Google Sign In | US |
| Functional Software, Inc. (Sentry) | Error and crash reporting | US |
| Microsoft Corporation (Clarity) | Session replay & heatmaps (anonymous analytics) | US / global |

International transfers (EU→US, EU→KR) rely on the **EU Commission Standard Contractual Clauses (2021/914/EU)** or equivalent safeguards. Counsel review pending for completeness of vendor DPAs.

### 6. Your Rights
- **GDPR (EU/EEA/UK)**: access, rectification, erasure, restriction, portability, objection, withdrawal of consent, lodging a complaint with your supervisory authority. We do not perform automated decisions producing legal effects.
- **CCPA/CPRA (California)**: right to know, delete, correct, opt out of sale/share, limit sensitive PI, non-discrimination. **We do not sell or share personal information** for cross-context behavioral advertising. Categories sold in the past 12 months: **none**.
- **PIPA (Korea)**: access, correction, deletion, suspension of processing, withdrawal of consent.

Submit requests to `heobusy@gmail.com` or via Settings → Delete Account. **SLA: confirmation in 3 business days; deletion within 72 hours; other requests within 1 month (GDPR), extendable to 2 months for complex cases.**

Pro Members can export their MIDI/WAV directly in-app. Bulk backend data export UI is planned for a P1 release; meanwhile available on email request.

### 7. Security
TLS 1.3 in transit; encryption at rest for the account, subscription and receipt records in Supabase; Supabase Row-Level Security; OAuth via Apple/Google (we never store your password); Sentry runs with default PII collection disabled and identifies signed-in users only by an opaque Supabase user ID; Microsoft Clarity auto-masks input fields. Your work stays on your device and is protected by your device's OS. We are a small operation and do not currently hold formal certifications (e.g., ISO 27001, SOC 2).

### 8. Children
We do not knowingly collect data from children under 14 (under 13 for U.S. COPPA). App Store / Google Play age rating is set to restrict download. Parents may contact us to delete a child's data.

### 9. Data Protection
- **Privacy lead**: Kim Dong Hyun (Representative), heobusy@gmail.com
- **EU Representative (GDPR Art. 27)**: Not designated at this time. EU/EEA users may exercise all GDPR rights (access, rectification, erasure, portability, objection, complaint, etc.) directly via the email above and we will respond. We will appoint an EU representative and amend this policy if EU usage grows to a material level.

EU/EEA residents may also lodge a complaint with their national supervisory authority if they consider this insufficient.

### 10. Changes
We give 30 days' in-app and email notice for material changes. Minor edits are reflected in the "Last updated" date.

---

## 변경 이력 (Change Log)

| 버전 | 일자 | 변경 사항 |
|---|---|---|
| 1.0-draft | 2026-06-02 | 1차 초안 (Humming 명의) |
| 1.1-draft | 2026-06-03 | HumTrack 리브랜딩, Fly.io iad 명시, Sentry/PostHog 를 "(예정)" 으로 명확히 표시, 30일 grace + 90일 webhook 로그 보유 명시, CCPA "no sale" 명시 강화, ATT 미사용 명시, OAuth sub 항목 추가, EU Rep TODO 항목 추가, SCC 2021/914/EU 명시 |
| 1.2-draft | 2026-06-03 | Pro 영구 보관으로 보유 기간 정정 (30일 grace 제거), 휴면 계정 정책 명시 (1+1년 모델), 사업자 정보 채움 (에르모세아르 / 대표 김동현 / 106-16-34319 / 주소 / 연락처), EU 대리인 미지정 결정 명시 (옵션 3 — 사용자 임계 도달 시 추후 지정), "단독 개발자" 표기 제거 |
| 1.3-draft | 2026-09-04 | **처리 사실관계 정정** — Pro 사용자의 보컬·작업물이 Cloudflare R2 / Supabase 에 저장·영구 보관된다는 기재를 삭제. 실제로는 곡·보컬·MIDI 가 회원 기기에만 저장되며 서버에 업로드되지 않음. 서버가 처리하는 것은 분석(/analyze)·보컬 처리(/process_vocal)·오토튠(/autotune)·이펙트(/process_fx) 요청 오디오(메모리 처리 후 즉시 폐기)와 계정 정보(Supabase Auth) · 구독 기록(스토어·상품·상태·만료일·스토어 거래 ID)임을 명시. 수탁자 표 및 5GB quota·마지막 동기화 시각 항목 정정. 계정 삭제 약속(72시간 cascade 삭제, 영업일 3일 SLA)과 이용자 권리는 변경 없이 유지. 시행일 2026-10-06 (30일 사전 고지 적용). / **Corrected the processing facts**: removed the claim that Pro vocals and projects are stored in Cloudflare R2 / Supabase and retained permanently — songs, vocals and MIDI live only on the member's device. Server-side we process audio in memory for /analyze, /process_vocal, /autotune and /process_fx (discarded immediately) and store account data (Supabase Auth) plus the subscription row (store, product, status, expiry, store transaction id). Subprocessor table corrected. Deletion commitments and user rights unchanged. Effective 2026-10-06 after 30 days' notice. |
| 1.3-draft | 2026-09-04 | **분석·진단 도구 고지를 실제 탑재 상태에 맞게 정정** — Sentry 를 "(예정)" 에서 활성으로 변경(앱·백엔드 모두 가동 중, 오류·크래시 리포팅, 서버 `send_default_pii=False` · 앱 `sendDefaultPii = false`, 로그인 사용자는 Supabase 사용자 ID(불투명 UUID)로만 식별). **Microsoft Clarity(세션 리플레이·히트맵) 고지를 신규 추가** — 수집 항목 표, 설명 문단(마스킹 범위 및 Supabase 사용자 ID 전달 사실 포함), 처리 목적, 수탁자 표 4곳 모두. 실제로 사용하지 않는 **PostHog 를 수집 항목·처리 목적·수탁자 표·"예정 항목" 안내에서 전면 삭제**. 「예정 항목 표시」 안내를 「분석·진단 도구 안내」로 교체. 세션 리플레이는 신규 고지 항목이므로 제10조에 따라 시행일 30일 전 사전 고지 필요. / **Analytics disclosure corrected to match what the app actually ships**: Sentry moved from "(Planned)" to active (live in both the app and the backend; error and crash reporting; `send_default_pii=False` on the server and `sendDefaultPii = false` in the app; signed-in users identified only by an opaque Supabase user ID). **Microsoft Clarity (session replay and heatmaps) newly disclosed** across all four places — collection table, explanatory paragraph (masking scope and the fact that the Supabase user ID is passed), purposes, and subprocessor table. **PostHog, which processes nothing, removed entirely** from the collection table, purposes, subprocessor table and the "planned services" note. Session replay is a new disclosure, so the 30-day prior notice under Section 10 applies. |

## 연락처

- **이메일**: heobusy@gmail.com
- **운영자**: 에르모세아르 / 대표 김동현
