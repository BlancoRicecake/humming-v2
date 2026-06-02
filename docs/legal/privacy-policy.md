**최종 갱신: 2026-06-02**
**상태: 변호사 검토 전 1차 초안 (DRAFT — for legal counsel review)**

> Disclaimer: This document is a working draft prepared by the product team for legal counsel review. It does not constitute legal advice. Final review by counsel competent in Korean PIPA, EU GDPR, and U.S. CCPA/CPRA is required prior to publication.

---

# Humming 개인정보처리방침 (Privacy Policy)

본 방침은 한국어 본문과 영문 본문(English below)을 함께 제공합니다.

---

## TL;DR — Privacy First, In Plain Language

- 우리는 **당신의 보컬 녹음을 광고나 AI 학습에 절대 사용하지 않습니다.**
- 무료 사용자의 보컬은 분석 직후 메모리에서 폐기됩니다. 클라우드에 저장되지 않습니다.
- Pro 사용자의 보컬과 프로젝트만 클라우드(Cloudflare R2 / Supabase)에 저장되며, **당신이 삭제하면 즉시 영구 삭제됩니다.**
- 결제 정보는 Apple/Google 이 처리하며 우리는 영수증 ID 외 카드 정보를 보지 못합니다.
- 익명 행동 분석(PostHog)은 디바이스 ID 기반이며 이름·이메일과 연결되지 않습니다.
- 데이터 열람·수정·삭제·이전 요청은 언제든 가능합니다 → `support@hum-track.com`

---

## 한국어 본문

### 1. 처리 항목 및 수집 방법

| 항목 | 수집 시점 | 처리 위치 | 보유 기간 |
|---|---|---|---|
| 이메일, OAuth 식별자 (Apple/Google sub) | 회원가입 시 | Supabase Auth | 회원 탈퇴 시까지 |
| 디바이스 ID (익명 UUID), OS 버전, 앱 버전 | 앱 실행 시 | PostHog | 익명 상태 유지 (재식별 불가) |
| 보컬 음성 녹음 (분석용) | 사용자가 "분석" 실행 시 | 서버 메모리 | **즉시 폐기** (저장 안 함) |
| 보컬 WAV (Pro 전용) | Pro 사용자가 동기화/업로드 시 | Cloudflare R2 | 사용자 명시 삭제 시까지 |
| 프로젝트 메타·MIDI 노트 (Pro 전용) | Pro 사용자가 동기화 시 | Supabase Postgres (us-east-1) | 사용자 명시 삭제 시까지 |
| IAP 영수증 / 구독 상태 | 결제 시 | Supabase Postgres | 영수증 검증·세무 목적 5년 |
| 에러 로그 (Sentry, PII 마스킹) | 앱 크래시 시 | Sentry | 90일 |

### 2. 처리 목적
- 서비스 제공 (계정 인증, 클라우드 백업, 다기기 복원, 보컬 분석)
- 결제 및 구독 관리 (영수증 검증, 청구·환불)
- 행동 분석을 통한 제품 개선 (익명, 집계 기반)
- 보안 (이상 접속 탐지, 에러 추적)
- 법령상 의무 이행 (세법, 전자상거래법 등)

### 3. 보유 및 파기
- 회원 탈퇴 또는 "계정 삭제" 요청 시: **Cloudflare R2 의 모든 보컬 파일과 Supabase 의 모든 프로젝트·계정 데이터를 72시간 이내 영구 삭제**합니다.
- IAP 영수증 등 법령상 보존 의무가 있는 데이터는 해당 기간(전자상거래법상 5년 등) 보관 후 파기합니다.
- 익명 분석 데이터는 개인과 연결되지 않으므로 별도 삭제 대상이 아닙니다.

### 4. 처리 위탁 (Subprocessors)

| 수탁자 | 위탁 업무 | 국가/리전 |
|---|---|---|
| Supabase Inc. | DB·인증 호스팅 | 미국 (us-east-1) |
| Cloudflare, Inc. | 보컬 WAV 객체 스토리지 (R2) | 글로벌 (사용자 인접 리전) |
| Functional Software, Inc. (Sentry) | 에러 추적 | 미국 |
| PostHog Inc. | 익명 행동 분석 | 미국/EU |
| Apple Inc. | iOS IAP 처리 | 미국 |
| Google LLC | Android IAP 처리 | 미국 |

EU/EEA 거주자의 개인정보가 한국·미국으로 이전되는 경우, 표준계약조항(SCC) 또는 동등한 적정성 보호 장치를 통해 보호됩니다.

### 5. 이용자 권리
회원은 다음 권리를 보유하며, `support@hum-track.com` 또는 앱 내 "설정 → 계정 삭제"를 통해 행사할 수 있습니다.
- 열람권 / 정정권 / 삭제권 / 처리 정지권 / 데이터 이동권
- (GDPR) 자동화된 의사결정 거부권 — 단, 본 서비스는 자동화된 결정을 수행하지 않습니다.
- (CCPA/CPRA) "Do Not Sell or Share My Personal Information" — **우리는 개인정보를 판매·공유하지 않습니다.**
- (한국 PIPA) 개인정보 열람·정정·삭제·처리정지 요구권

**계정 삭제 요청 처리 SLA: 영업일 기준 3일 이내 접수 확인, 72시간 이내 R2 + Supabase 전면 삭제.**

### 6. 보안 조치
- TLS 1.3 전송 암호화
- R2 객체 서버측 암호화 (AES-256)
- Supabase RLS(Row-Level Security)로 사용자별 데이터 격리
- Sentry PII 마스킹 (이메일·토큰·경로 자동 redact)

### 7. 만 14세 미만 아동
회사는 만 14세 미만 아동의 개인정보를 의도적으로 수집하지 않습니다. 보호자가 자녀의 미등록 사용을 발견한 경우 위 이메일로 통보 시 즉시 삭제합니다.

### 8. 개인정보보호 책임자 / DPO
- 책임자: [PLACEHOLDER 이름]
- 직위: [PLACEHOLDER]
- 이메일: support@hum-track.com
- 주소: [PLACEHOLDER]

EU 거주자는 거주국 데이터보호감독기구(예: 독일 BfDI, 프랑스 CNIL)에 진정을 제기할 권리를 가집니다.

### 9. 변경 고지
본 방침은 법령·서비스 변경에 따라 개정될 수 있습니다. 중대한 변경은 시행일 30일 전 앱 내 공지 및 가입 이메일로 고지합니다. 사소한 변경은 본 페이지 상단의 "최종 갱신" 일자로 안내합니다.

---

## English Version

### 1. Data We Collect

| Data | When | Where | Retention |
|---|---|---|---|
| Email, OAuth subject (Apple/Google) | Sign-up | Supabase Auth | Until account deletion |
| Anonymous device UUID, OS/app version | App launch | PostHog | Anonymous, no re-identification |
| Vocal audio for analysis | When you tap "Analyze" | Server memory only | **Discarded immediately** |
| Vocal WAV (Pro only) | Pro sync/upload | Cloudflare R2 | Until you delete it |
| Project metadata, MIDI notes (Pro only) | Pro sync | Supabase Postgres (us-east-1) | Until you delete it |
| IAP receipts, subscription status | Purchase | Supabase Postgres | 5 years (tax/billing) |
| Error logs (PII masked) | App crash | Sentry | 90 days |

### 2. How We Use Data
Service operation, payment verification, anonymous product analytics, security, and legal compliance. **We never use your vocal recordings or music for advertising, ML/AI training, or resale.**

### 3. Retention and Deletion
On account deletion request, **we permanently erase all R2 vocal files and Supabase project/account data within 72 hours.** IAP receipts may be retained for up to 5 years for tax compliance. Anonymous analytics are not tied to identities and are not individually deletable.

### 4. Subprocessors
Supabase (US), Cloudflare R2 (global), Sentry (US), PostHog (US/EU), Apple (US), Google (US). International transfers (e.g., EU→US, EU→KR) rely on Standard Contractual Clauses or equivalent safeguards.

### 5. Your Rights
- **GDPR (EU/EEA/UK)**: access, rectification, erasure, restriction, portability, objection, right to lodge a complaint with your supervisory authority.
- **CCPA/CPRA (California)**: right to know, delete, correct, opt out of "sale/share." **We do not sell or share personal information.**
- **PIPA (Korea)**: access, correction, deletion, suspension of processing.

Submit requests to `support@hum-track.com` or via Settings → Delete Account. **SLA: confirmation within 3 business days, full deletion within 72 hours.**

### 6. Security
TLS 1.3 in transit; AES-256 at rest in R2; Supabase Row-Level Security; Sentry PII scrubbing.

### 7. Children
We do not knowingly collect data from children under 14 (under 13 for U.S. users under COPPA). Parents may contact us to delete a child's account.

### 8. Data Protection Officer
- Name: [PLACEHOLDER]
- Email: support@hum-track.com
- Address: [PLACEHOLDER]

### 9. Changes
We will notify material changes at least 30 days in advance via in-app notice and email. The "Last Updated" date at the top reflects the current version.

---

**Contact**: support@hum-track.com
