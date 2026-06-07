# HumTrack 개인정보처리방침 (Privacy Policy)

**시행일**: 2026-06-04
**최종개정**: 2026-06-03
**상태**: 1.2-draft — 사업자 정보 + 정책 사실관계 확정. 변호사 자문 권장 5건은 출시 후 진행 가능.

> Disclaimer: 본 문서는 출시 전 외부 변호사 검토를 전제로 한 작업본입니다. 한국 PIPA, EU GDPR, 미국 CCPA/CPRA 에 대한 자격 있는 변호사의 최종 검토 후 효력이 확정됩니다.

본 방침은 한국어 본문과 영문 본문(English below)을 함께 제공하며, 두 언어 본문은 동등하게 유효합니다.

---

## TL;DR — 한 줄 요약

- **당신의 보컬 녹음은 광고나 AI 학습에 절대 사용되지 않습니다.**
- 무료 사용자의 보컬은 분석 서버 메모리에서 처리된 후 **즉시 폐기**됩니다 (디스크에 기록 ❌).
- Pro 사용자의 보컬·작업물만 Cloudflare R2 / Supabase 에 저장되며, **사용자가 직접 삭제하거나 회원 탈퇴할 때까지 영구 보관**됩니다. 구독 만료 후에도 보관됩니다.
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
| 보컬 음성 녹음 (Opus 16kHz mono, .caf/.ogg) — 분석용 | "분석" 실행 시 | Fly.io iad 서버 메모리 | **분석 완료 즉시 폐기** | 계약 이행 |
| 보컬 파일 (Pro 전용) | Pro 사용자 동기화 시 | Cloudflare R2 (us-east-1) | 회원이 직접 삭제 또는 회원 탈퇴 시까지 영구 보관 (구독 만료와 무관) | 계약 이행 |
| 프로젝트 메타 (제목, BPM, 트랙) | Pro 사용자 동기화 시 | Supabase Postgres (us-east-1) | 회원이 직접 삭제 또는 회원 탈퇴 시까지 영구 보관 (구독 만료와 무관) | 계약 이행 |
| IAP 영수증 (transactionId, productId, expiresAt) | 결제·갱신 시 | Supabase Postgres | 90일 (webhook 로그) / 5년 (영수증, 세법) | 법령 의무 |
| 사용 통계 (분석 횟수, 업로드 크기 — 5GB quota 추적) | 기능 사용 시 | Supabase Postgres | 회원 탈퇴 시까지 | 계약 이행 |
| 디바이스 모델, OS 버전, 앱 버전 | API 호출 시 | Supabase Postgres / 서버 로그 | 90일 | 정당한 이익 (보안·호환성) |
| 마지막 동기화 시각 | 동기화 시 | Supabase Postgres | 회원 탈퇴 시까지 | 계약 이행 |
| (예정) 에러 스택 트레이스 (PII 마스킹) | 앱 크래시 시 | Sentry (미국) | 90일 | 정당한 이익 (안정성) |
| (예정) 익명 사용 이벤트 (anonymous_id) | 앱 사용 시 | PostHog (미국 또는 EU) | 12개월, 개인 미연결 | 정당한 이익 (제품 개선) |

**중요 (수집하지 않는 항목)**:
- 결제 카드 번호 직접 처리 ❌ (Apple / Google 이 처리)
- 위치 정보 ❌
- 연락처 ❌
- 사진 라이브러리 접근 ❌
- 광고 추적 식별자 (IDFA, AAID) ❌ — iOS ATT 권한도 요청하지 않습니다.

**예정 항목 표시**: 위 표에 "(예정)" 으로 표기된 Sentry, PostHog 는 본 약관 시행 시점(2026-06-04) 기준 아직 통합되지 않았으며, 통합 시 본 방침을 개정하여 30일 전 사전 고지합니다.

### 3. 처리 목적
1. 서비스 제공: 계정 인증, 보컬 분석, Pro 클라우드 동기화 및 복원
2. 결제 및 구독 관리: IAP 영수증 검증, 갱신 webhook 처리, 5GB quota 추적
3. (예정) 안정성 개선: 에러 추적 (Sentry, 익명화)
4. (예정) 제품 개선: 익명 사용 분석 (PostHog, anonymous_id 기반)
5. 보안: 이상 접속 탐지, API rate limiting
6. 법령상 의무: 세법, 전자상거래법, 전자금융거래법

### 4. 보유 및 파기
1. **회원 탈퇴 시**: Cloudflare R2 의 보컬 파일, Supabase Auth/Postgres 의 계정·프로젝트 데이터를 **72시간 이내 cascade 영구 삭제**합니다 (SLA: 영업일 기준 3일 이내 접수 확인).
2. **Pro 구독 만료 시**: 클라우드 작업물은 **자동 삭제되지 않으며** 회원이 직접 삭제하거나 회원 탈퇴할 때까지 영구 보관됩니다. 단, 만료 후에는 신규 업로드 및 동기화가 잠금되며, 기존 작업물의 다운로드 및 삭제만 가능합니다. 별도의 휴면 계정 정책이 향후 도입될 경우 시행일 30일 전 본 방침 개정을 통해 사전 고지합니다.
3. **IAP 영수증**: 「전자상거래법」 및 「전자금융거래법」 상 보존 의무에 따라 결제·계약 기록은 5년 보관.
4. **IAP webhook 알림 로그**: 90일.
5. **무료 사용자 보컬**: 분석 서버 메모리에서 처리 후 즉시 폐기 (영구 저장 ❌).

### 5. 처리 위탁 (Subprocessors)

| 수탁자 | 위탁 업무 | 리전 | 데이터 |
|---|---|---|---|
| Supabase Inc. | DB·인증 호스팅 | 미국 (AWS us-east-1) | 계정, 프로젝트 메타, 영수증 |
| Cloudflare, Inc. | 객체 스토리지 (R2), DNS | 미국 (us-east-1) | Pro 보컬 파일 |
| Fly.io, Inc. | 백엔드 분석 서버 호스팅 | 미국 (iad — Ashburn, VA) | 보컬 (메모리 처리, 즉시 폐기) |
| Apple Inc. | iOS IAP 처리, Apple Sign In | 미국 | 영수증, OAuth sub |
| Google LLC | Android IAP 처리, Google Sign In | 미국 | 영수증, OAuth sub |
| (예정) Functional Software, Inc. (Sentry) | 에러 추적 | 미국 | 에러 stack trace (PII 마스킹) |
| (예정) PostHog Inc. | 익명 행동 분석 | 미국 또는 EU | anonymous_id, 이벤트 |

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
- **저장 구간**: Cloudflare R2 서버측 암호화 (AES-256), Supabase 저장 데이터 암호화
- **접근 통제**: Supabase Row-Level Security (사용자별 데이터 격리), 백엔드 API JWT 검증
- **인증**: OAuth via Apple / Google (회사가 비밀번호를 직접 저장 ❌)
- **PII 마스킹**: (예정) Sentry 통합 시 이메일·토큰·파일 경로 자동 redact

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
| Vocal audio for analysis (Opus 16 kHz mono) | "Analyze" action | Fly.io iad server memory | **Discarded immediately** | Contract |
| Pro vocal files | Pro sync | Cloudflare R2 (us-east-1) | Retained until you delete the content or your account (regardless of subscription state) | Contract |
| Project metadata (title, BPM, tracks) | Pro sync | Supabase Postgres (us-east-1) | Retained until you delete the content or your account (regardless of subscription state) | Contract |
| IAP receipts (transactionId, productId, expiresAt) | Purchase/renewal | Supabase Postgres | 90 days webhook log; 5 years receipts (tax) | Legal obligation |
| Usage counters (analyses, upload bytes for 5 GB quota) | Feature use | Supabase Postgres | Until deletion | Contract |
| Device model, OS / app version | API call | Supabase Postgres / logs | 90 days | Legitimate interest |
| (Planned) Error stack traces (PII masked) | Crash | Sentry (US) | 90 days | Legitimate interest |
| (Planned) Anonymous events (anonymous_id) | Use | PostHog (US/EU) | 12 months, not linked to identity | Legitimate interest |

**We do NOT collect**: payment card numbers (Apple/Google handle), location, contacts, photo library, ad identifiers (IDFA/AAID — we never request iOS ATT permission).

**"Planned" services** (Sentry, PostHog) are not integrated as of 2026-06-04. We will amend this policy with 30 days' notice before activation.

### 3. Purposes
Service operation, payment management, security, planned stability/product analytics, legal compliance (Korean tax law and Electronic Commerce Act).

**We never use vocal recordings, analysis results, or generated music for advertising, AI/ML training, third-party resale, or our own marketing without your explicit consent.**

### 4. Retention and Deletion
- **Free vocals**: discarded immediately after analysis (memory only, never on disk).
- **Pro cloud content**: retained **permanently until you delete the content or your account**, regardless of subscription state. After expiration, new uploads/syncs are locked but existing content can still be downloaded or deleted. A future dormant-account policy may be introduced with 30 days' prior notice.
- **Account deletion request**: cascade delete from Supabase Auth, Supabase Postgres, and Cloudflare R2 within **72 hours**, with confirmation in 3 business days.
- **IAP receipts**: retained 5 years per Korean Electronic Commerce Act / Electronic Financial Transactions Act.
- **Webhook logs**: 90 days.

### 5. Subprocessors

| Subprocessor | Purpose | Region |
|---|---|---|
| Supabase, Inc. | DB and auth hosting | US (AWS us-east-1) |
| Cloudflare, Inc. | R2 object storage, DNS | US (us-east-1) |
| Fly.io, Inc. | Backend analysis | US (iad, Ashburn VA) |
| Apple Inc. | iOS IAP, Sign In with Apple | US |
| Google LLC | Android IAP, Google Sign In | US |
| (Planned) Sentry | Error tracking | US |
| (Planned) PostHog | Anonymous analytics | US or EU |

International transfers (EU→US, EU→KR) rely on the **EU Commission Standard Contractual Clauses (2021/914/EU)** or equivalent safeguards. Counsel review pending for completeness of vendor DPAs.

### 6. Your Rights
- **GDPR (EU/EEA/UK)**: access, rectification, erasure, restriction, portability, objection, withdrawal of consent, lodging a complaint with your supervisory authority. We do not perform automated decisions producing legal effects.
- **CCPA/CPRA (California)**: right to know, delete, correct, opt out of sale/share, limit sensitive PI, non-discrimination. **We do not sell or share personal information** for cross-context behavioral advertising. Categories sold in the past 12 months: **none**.
- **PIPA (Korea)**: access, correction, deletion, suspension of processing, withdrawal of consent.

Submit requests to `heobusy@gmail.com` or via Settings → Delete Account. **SLA: confirmation in 3 business days; deletion within 72 hours; other requests within 1 month (GDPR), extendable to 2 months for complex cases.**

Pro Members can export their MIDI/WAV directly in-app. Bulk backend data export UI is planned for a P1 release; meanwhile available on email request.

### 7. Security
TLS 1.3 in transit; AES-256 at rest in R2; Supabase Row-Level Security; OAuth via Apple/Google (we never store your password); planned PII scrubbing in Sentry. We are a small operation and do not currently hold formal certifications (e.g., ISO 27001, SOC 2).

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

## 연락처

- **이메일**: heobusy@gmail.com
- **운영자**: 에르모세아르 / 대표 김동현
