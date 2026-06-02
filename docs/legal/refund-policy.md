**최종 갱신: 2026-06-02**
**상태: 변호사 검토 전 1차 초안 (DRAFT — for legal counsel review)**

> Disclaimer: This document is a working draft prepared by the product team for legal counsel review. Withdrawal rights under the Korean Electronic Commerce Act, the EU Consumer Rights Directive (2011/83/EU), and U.S. state consumer law require validation by qualified counsel.

---

# Humming 환불 정책 (Refund Policy)

본 문서는 한국어 본문과 영문 본문(English below)을 함께 제공합니다.

---

## 1. 기본 원칙: 스토어 IAP 정책 우선

Humming Pro 구독은 Apple App Store 또는 Google Play의 인앱결제(IAP)를 통해서만 판매됩니다. 환불 처리 권한은 **1차적으로 해당 스토어가 보유**하며, 회사는 스토어 정책에 종속됩니다.

- **Apple (iOS)**: https://support.apple.com/ko-kr/HT204084 — "App Store 환불 요청"
- **Google (Android)**: https://support.google.com/googleplay/answer/2479637 — "Google Play 환불 요청"

회사 측에 환불을 요청해 주셔도 결제 정보는 스토어가 보유하므로, 위 링크를 통한 직접 요청이 가장 빠릅니다.

## 2. 구독 취소와 사용 기간

- **자발적 취소**: 회원이 스토어에서 구독을 취소하면, **이미 결제한 기간 말까지 Pro 기능을 계속 사용**할 수 있으며, 만료 시점 이후에는 자동으로 무료(읽기 전용) 모드로 전환됩니다.
- **취소 = 즉시 환불 아님**: 스토어 IAP 특성상 취소는 다음 자동 갱신을 막는 행위이며, 잔여 기간에 대한 비례 환불은 기본 제공되지 않습니다.

## 3. 법정 청약철회권 (한국·EU)

### 한국 「전자상거래법」 (재화의 디지털콘텐츠 특칙)
- 디지털콘텐츠의 경우, **이용 개시 전 7일 이내**에 청약철회가 가능합니다.
- 7일 무료 체험 기간 중에는 결제가 발생하지 않으므로 환불 대상이 아닙니다. 체험 종료 후 자동 결제된 직후 사용을 개시하지 않은 상태에서는 결제일로부터 7일 이내 회사로 직접 요청 시 환불 검토합니다.
- 이미 다운로드·동기화·내보내기 기능을 사용한 경우 디지털콘텐츠 특성상 청약철회권이 제한될 수 있습니다.

### EU 소비자권리지침 (2011/83/EU)
- 디지털콘텐츠 구매 후 **14일 청약철회권**이 원칙입니다.
- 단, 사용자가 구매 시 "즉시 콘텐츠 다운로드/사용에 동의하며 철회권 상실에 동의한다"는 명시적 동의를 제공한 경우 철회권이 소멸할 수 있습니다 (지침 제16조 m항).
- 회사는 결제 흐름에서 해당 동의 여부를 명확히 표시합니다.

## 4. 회사가 직접 환불을 검토하는 케이스

스토어를 통한 환불이 거부된 경우에도, 다음에 해당하면 회사가 직접 환불을 검토합니다 (스토어 환불 처리가 기술적으로 불가능한 영역에 한함):

1. **결제 오류**: 동일 기간 중복 결제, 명백한 시스템 오류로 인한 부당 청구
2. **서비스 장애**: 회사 측 원인으로 **연속 7일 이상** 핵심 기능(클라우드 동기화·내보내기 등) 사용 불가
3. **회사가 약관을 중대하게 위반**한 경우

요청 채널: `support@hum-track.com` — 결제 영수증 ID(스토어), 발생 일시, 증빙(스크린샷 등) 첨부 필수.
처리 SLA: 영업일 기준 **5일 이내 1차 회신**, 필요 시 추가 조사 후 **14일 이내 최종 결정**.

## 5. 환불되지 않는 경우

- 회원의 단순 변심으로 위 청약철회 기간을 도과한 경우
- 회원의 약관 위반으로 인한 계정 정지
- 제3자(Apple/Google/Supabase/Cloudflare)의 일시적 장애 (회사 책임 범위 밖)
- 디바이스 분실·로컬 데이터 손실 등 회사가 통제할 수 없는 사유

## 6. 데이터 보존

환불 여부와 무관하게, **클라우드 데이터는 자동 삭제되지 않습니다.** 회원이 명시적으로 계정 삭제를 요청하지 않는 한 R2 / Supabase 데이터는 보존되며, 향후 재구독 시 즉시 복원됩니다.

---

## English Version

### 1. Stores Govern IAP Refunds
Humming Pro is sold exclusively via Apple App Store or Google Play in-app purchase. The store of purchase holds primary refund authority. Submit refund requests directly:
- **Apple**: https://support.apple.com/HT204084
- **Google**: https://support.google.com/googleplay/answer/2479637

### 2. Cancellation vs. Refund
Canceling your subscription stops the next renewal but does not trigger a prorated refund. You retain Pro access until the end of the paid period; the app then switches to free, read-only mode.

### 3. Statutory Withdrawal Rights
- **Korea (Electronic Commerce Act)**: 7-day withdrawal for digital content not yet consumed. The 7-day free trial is not a paid charge. If you have not used Pro features after the first charge, contact us within 7 days.
- **EU (Directive 2011/83/EU)**: 14-day withdrawal for digital content unless you expressly consented to immediate performance and acknowledged loss of withdrawal at checkout (Art. 16(m)). We surface this consent in the purchase flow.
- **United States**: Subject to applicable state consumer law; California subscribers have rights under the Automatic Renewal Law (cal. BPC §17600 et seq.) — see counsel.

### 4. Company-Initiated Refund Review
Where store-level refunds fail, we will independently review:
1. **Duplicate or erroneous charges**
2. **Service outage caused by us lasting 7+ consecutive days** affecting core Pro features (cloud sync, export)
3. **Material breach of these Terms by us**

Submit to `support@hum-track.com` with the store receipt ID, timestamp, and evidence. **SLA: first response within 5 business days; final decision within 14 days.**

### 5. Non-Refundable Situations
- Change of mind beyond statutory withdrawal windows
- Account suspension for Terms violations
- Transient third-party outages (Apple, Google, Supabase, Cloudflare)
- Lost device or local data outside our control

### 6. Data is Not Auto-Deleted
Refund status does not affect data retention. Cloud data (R2 + Supabase) is preserved until you explicitly delete your account, and resubscribing restores immediate access.

---

**Contact**: support@hum-track.com
