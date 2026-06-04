# HumTrack 법무 검토 노트 (Review Notes)

**최종 갱신**: 2026-06-03
**문서 시행 예정일**: 2026-06-15
**대상**: 외부 변호사 (한국 / 미국 / EU), 사용자 (placeholder 채움 책임자)

본 문서는 `terms-of-service.md`, `privacy-policy.md`, `refund-policy.md` 1.1-draft 에 대한 출시 전 검토 가이드입니다. 사업 사실관계 (소규모 한국 사업자, IAP only, Cloudflare R2 + Supabase + Fly.io 인프라) 기준으로 작성되었습니다.

---

## A. 사용자가 즉시 채워야 할 Placeholder (총 11개)

문서 시행 전(2026-06-15) 반드시 채워야 하는 항목입니다. 모두 `[xxx: TODO]` 형식으로 표기되어 있습니다.

| # | 항목 | 위치 | 비고 |
|---|---|---|---|
| 1 | 사업자명 (상호) | terms 1조, 13조; privacy 1조, 9조; refund 푸터 | 개인사업자명 또는 법인명 |
| 2 | 사업장 주소 | terms 13조; privacy 1조 | 사업자등록증 주소 |
| 3 | 사업장 전화번호 | terms 13조 | 전상법 13조 표시 의무. 휴대폰 가능하나 권장 ❌ |
| 4 | 사업자등록번호 | terms 13조; privacy 1조 | 10자리 |
| 5 | 통신판매업 신고번호 | terms 13조 | **현재 미신고 시 출시 전 신고 필수** (관할 구청) |
| 6 | EU 대리인 (GDPR Art. 27) 지정 여부 + 정보 | privacy 9조 | 변호사 검토 필요. 소규모 예외 적용 검토 후 결정 |
| 7 | DPA / DPO 책임자 직위 | privacy 9조 | 소규모 운영 시 "대표 겸임" 표기 가능 |

**선택 (변호사 결정 사항)**:
| # | 항목 | 비고 |
|---|---|---|
| 8 | terms 12조 미국 분쟁 해결 — arbitration / class action waiver 도입 여부 | FAA 호환성 + California McGill rule |
| 9 | refund 3조 미국 — California ARL 외 다른 주별 추가 조항 | 변호사 검토 |
| 10 | privacy 7조 보안 — 추가 인증 보유 시 명시 | 현재 없음, 추후 ISO 27001 등 획득 시 |
| 11 | terms 12조 한국 분쟁 — 서울중앙지방법원 합의 관할 (현재 명시) | 사업장이 서울이 아닌 경우 사업장 관할 법원으로 변경 검토 |

---

## B. 변호사 최종 검토 권장 사항 — 우선순위 5개

### B1. (최우선) 한국 「전자상거래법」 청약철회 제한 — "이용 개시" 정의
**문서**: refund-policy.md §3 한국
**쟁점**: 디지털콘텐츠는 "이용 개시" 시 청약철회권 제한이 가능하나, "이용 개시" 의 정의가 모호. 본 초안은 "분석 endpoint 1회 실행 또는 Pro 전용 기능(export/sync) 1회 사용" 을 trigger 로 설정하고, 그 직전에 사용자 명시 동의 surface 를 두는 것으로 설계.
**리스크**: 공정위 표준약관 또는 최근 판례와 정합 여부 검토 필요. "동의 surface" 의 구체적 UI 표현 (체크박스 + 명시 문구) 이 「약관규제법」상 "불공정약관" 으로 해석되지 않도록 검토.
**Action**: 변호사 검토 + 결제 직후 첫 Pro 사용 직전 modal UI 구현 (개발 작업 동반).

### B2. EU GDPR 데이터 이전 — SCC 체결 및 EU Representative 지정
**문서**: privacy-policy.md §5, §9
**쟁점**:
- 본 초안은 SCC (2021/914/EU) 를 명시했으나, 각 subprocessor (Supabase, Cloudflare, Fly.io, Apple, Google) 의 DPA 가 SCC 모듈 1 (controller-processor) 을 포함하는지 vendor 별 확인 필요.
- GDPR Art. 27 EU Representative 지정 의무: 회사가 EU 거주자에게 의도적으로 서비스 제공 시 의무. HumTrack 은 다국어 UI 제공 + EU 거주자 결제 허용 → 적용 가능성 큼. 단 Art. 27(2) "처리가 occasional + low-risk" 예외 적용 가능 여부 검토.
**리스크**: Art. 27 위반 시 GDPR Art. 83(4) 최대 €10M 또는 글로벌 매출 2% 과징금.
**Action**: (a) vendor DPA 확보 및 보관, (b) EU 대리인 서비스(예: Prighter, EU-Rep.com) 가입 여부 결정.

### B3. 미국 분쟁 해결 — Arbitration 도입 여부
**문서**: terms-of-service.md §12.3
**쟁점**: 본 초안은 "성실한 협의" 만 명시하고 arbitration / class action waiver 를 의도적으로 비워둠. 소규모 사업자가 미국 class action 에 노출되는 리스크 vs. 한국 거주자가 미국 arbitration 을 운영할 수 없는 현실의 trade-off.
**Action**: 변호사 검토. 대안 — (a) "본인 거주 한국 법원 외에는 강행법 한도 내에서 면책" 조항, (b) AAA Online Arbitration 도입 + 소규모 사업자 비용 부담 조항 검토.

### B4. CCPA — PostHog "share" 해석
**문서**: privacy-policy.md §6
**쟁점**: PostHog 가 통합되면 anonymous_id 기반 이벤트 수집이 발생. 본 초안은 "(예정)" 표시 + "no sale/share" 명시. CPRA 의 "share" 정의는 cross-context behavioral advertising 목적 공유를 포함. PostHog 자체는 광고 SDK 아니나, 향후 retargeting 통합 시 share 해당 가능.
**Action**: PostHog 통합 전 SDK 설정 검토 (광고 식별자 비활성, anonymous_id only). 통합 시 본 방침 30일 사전 고지.

### B5. 소규모 사업자 운영 책임 — Limitation of Liability + 보험
**문서**: terms-of-service.md §10
**쟁점**: 소규모 사업자가 글로벌 사용자 대상 서비스 운영. "12개월 구독료" 책임 제한이 한국 「약관규제법」상 "불공정약관" 으로 해석될 수 있음 (대법원 2018다XXX 류 판례 검토).
**Action**: (a) E&O / Cyber Liability 보험 가입 검토, (b) 책임 제한 문구를 강행법 한도 내로 정확히 한정, (c) 한국 약관규제법상 무효 가능성을 변호사 의견서로 정리.

---

## C. App Store / Google Play 심사 차단 위험 항목

### C1. 4 위치 가격/갱신/해지 일관성 (Apple Guideline 5.1.1, 3.1.2 / Google Play Policy)
**필수**: 다음 4 위치에서 가격, 갱신 주기, 자동갱신, 해지 방법, 환불 처리가 **완전히 일치** 해야 함.
1. Paywall 화면 — 앱 UI (mobile/lib/screens/subscription_screen.dart 검토 필요)
2. 본 약관 §6 — ✓ 명시됨
3. App Store Connect / Play Console 제품 페이지 — **출시 시 등록**
4. 영수증 — Apple/Google 자동 처리

**위험**: paywall UI 와 약관의 가격/조건이 다르면 심사 reject. **현재 paywall 화면이 USD 3.49/USD 33.49 (현지 통화 자동 변환) + 7일 체험 + 자동갱신 + 해지 방법을 4 위치에 일치하게 표시하는지 출시 전 cross-check 필수**.

### C2. iOS Privacy Manifest (PrivacyInfo.xcprivacy)
**필수 (iOS 17+)**: 사용 SDK 의 reasons API + 수집 데이터 카테고리 선언. HumTrack 의 경우:
- Microphone (NSMicrophoneUsageDescription) — Info.plist
- File timestamp / disk space / system boot time API 사용 시 reason 명시
- Sentry / PostHog 등 3rd party SDK 도 자체 PrivacyInfo 보유해야 함 (예정 통합 시점에 확인)

**Action**: 출시 전 `mobile/ios/Runner/PrivacyInfo.xcprivacy` 작성. 본 Privacy Policy §2 표와 일치.

### C3. iOS App Store Connect — Nutrition Label
본 초안 §2 의 수집 항목과 다음 매핑:
- **Identifiers**: User ID (OAuth sub) — linked to identity, used for app functionality
- **Contact Info**: Email — linked, app functionality
- **User Content**: Audio (보컬), other user content (MIDI/메타) — linked, app functionality. **AI 학습 ❌ 명시 (이미 약관/방침에 있음)**
- **Usage Data**: Product Interaction (분석 횟수) — linked, app functionality
- **Diagnostics**: Crash Data, Performance Data — (예정 Sentry 통합 시) not linked
- **Purchases**: Purchase History — linked, app functionality

**ATT (App Tracking Transparency)**: **권한 요청 ❌** (Privacy Policy §2 명시). 추적 ID 사용 안 함.

### C4. Android Data Safety
Play Console "데이터 보안" 섹션:
- 수집 항목 (Audio, Email, User IDs, Purchase History 등)
- 공유 여부: **No** (제3자에게 판매·공유 안 함)
- 암호화: TLS in transit, AES-256 at rest
- 사용자 삭제 요청 경로: 앱 내 "설정 → 계정 삭제" + heobusy@gmail.com

**Action**: 출시 전 Play Console 작성, 본 Privacy Policy §2 와 100% 일치.

### C5. Apple Sign In — "Hide my email" 처리
**필수 (Apple Guideline 4.8)**: Apple Sign In 제공 시 다른 OAuth 와 동등하게 노출 (현재 Google Sign In 만 있으면 Apple Sign In 도 필수). Relay email 처리 절차를 약관에 명시 (terms-of-service.md §4.2 ✓).

**Action**: iOS 빌드에서 Apple Sign In 활성 확인. Apple 의 token revoke webhook 처리 구현 여부 검토 (Apple 권장).

---

## D. 우리 정책 결정 — Industry Standard 대비

### D1. 30일 Grace 기간 (Pro 만료 후 클라우드 보존)
- **Industry standard**:
  - Notion: 30일 (Pro → Free 다운그레이드 시 데이터 보존)
  - Spotify: 즉시 다운그레이드, playlist 는 영구 보존
  - Dropbox Plus: 30일 (downgrade 후)
  - Adobe CC: 90일 (구독 만료 후 cloud storage)
- **평가**: 30일은 합리적 표준. 다만 사용자가 "구독 만료 시 즉시 삭제" 를 기대할 수 있으므로 **본 정책을 약관과 IAP paywall 양쪽에 명시 + 만료 직전 이메일 알림 권장**.

### D2. 무료 사용자 보컬 즉시 폐기
- **Industry standard**:
  - Otter.ai: 무료도 30일 보관
  - 대다수 음성 분석 서비스는 무료도 일정 기간 보관
- **평가**: 즉시 폐기는 **사용자 친화적이고 privacy-first 한 차별점**. 단 "분석 결과 다시 받기" 같은 retry UI 가 없어진다는 trade-off — 제품 결정에 따라 유지.

### D3. 회원 탈퇴 시 72시간 삭제
- **GDPR**: "without undue delay, and in any event within one month" (1개월)
- **평가**: 72시간은 GDPR 보다 훨씬 strict 한 약속. **약속을 지킬 수 있는 구현이 backend 에 있는지 확인 필수**. 만약 R2 객체 삭제가 lifecycle policy 기반이면 72시간 보장이 어려울 수 있음. 현재 `backend/app/routes/account.py` 에 cascade delete 가 구현되어 있는지 검증 권장.

### D4. IAP 영수증 5년 보관
- **한국 「전자상거래법」 시행령 §6**: 계약 또는 청약철회 등에 관한 기록 5년, 대금결제 및 재화 등의 공급에 관한 기록 5년.
- **평가**: 합당. 영수증 raw JSON 이 아닌 정규화된 결제 기록만 보관해도 의무 충족.

### D5. 회사 직접 환불 ❌ (Goodwill 보충만)
- **평가**: 소규모 사업자 + IAP only 모델에서 합리적. 다만 한국 소비자가 "회사에 환불 요청했는데 거부당했다" 며 공정위 민원 제기할 가능성 있음. 본 초안의 "스토어 환불 권한이 1차, 회사는 보충" 표현 + 적극 지원 약속이 그 리스크를 어느 정도 완화함.

---

## E. iOS Privacy Nutrition Label / Android Data Safety 매핑 표

| Privacy Policy §2 항목 | iOS Nutrition Label | Android Data Safety |
|---|---|---|
| Email | Contact Info → Email Address (linked, app functionality) | Personal info → Email address (Collected, not shared) |
| OAuth provider/sub | Identifiers → User ID (linked, app functionality) | App info & performance → Other (User ID, Collected) |
| 보컬 (Free, 메모리 폐기) | Audio Data (NOT collected — memory only) | Audio files (Collected, not stored, see disclosure) |
| 보컬 (Pro, R2) | Audio Data → Audio (linked, app functionality) | Audio files (Collected, encrypted in transit + at rest) |
| MIDI / 프로젝트 메타 | User Content → Other User Content (linked) | Files and docs → Other files (Collected) |
| IAP 영수증 | Purchases → Purchase History (linked) | Financial info → Purchase history (Collected, encrypted) |
| 사용 통계 | Usage Data → Product Interaction (linked) | App activity → App interactions (Collected) |
| 디바이스 모델/OS | Diagnostics → Other Diagnostic Data (linked) | Device or other IDs (Collected, not shared) |
| (예정) Sentry crash | Diagnostics → Crash Data (not linked) | App info & performance → Crash logs (Collected, not linked) |
| (예정) PostHog | (예정 통합 시) Usage Data → Product Interaction (not linked) | App activity → App interactions (Collected, not linked) |

**ATT**: 요청 안 함 (terms/privacy 양쪽 명시).
**광고 ID**: 사용 안 함.

---

## F. 출시 전 체크리스트

- [ ] **Placeholder 11개 채움** (위 §A)
- [ ] **통신판매업 신고** (관할 구청, 미신고 시 출시 ❌)
- [ ] **변호사 검토** (위 §B 5개 우선순위 항목)
- [ ] **App Store Connect** — 가격, 약관 URL, 개인정보 URL, Nutrition Label 등록
- [ ] **Play Console** — 가격, 약관 URL, 개인정보 URL, Data Safety 등록
- [ ] **iOS PrivacyInfo.xcprivacy** 작성
- [ ] **Paywall UI cross-check** (가격/갱신/해지가 약관과 일치)
- [ ] **첫 Pro 사용 직전 동의 surface** UI 구현 (한국 청약철회 제한 trigger 명시)
- [ ] **연간 갱신 7일 전 알림** 자동화 (전상법 2022 의무)
- [ ] **EU Rep 지정** 또는 면제 검토 (변호사 의견서)
- [ ] **vendor DPA 수집** (Supabase, Cloudflare, Fly.io, Sentry [예정], PostHog [예정])
- [ ] **백엔드 cascade delete 검증** — 72시간 삭제 SLA 보장 (`backend/app/routes/account.py` review)
- [ ] **Apple Sign In token revoke webhook** 구현 (Apple 권장)

---

## G. 본 작업의 한계

- **변호사 자문 대체 ❌**: 본 문서는 사업 사실관계와 일반적 모범 사례에 기반한 작업본입니다. 한국 「전자상거래법」, EU GDPR, 미국 CCPA/CPRA 의 최신 판례 및 가이드라인 적용은 자격 있는 변호사가 최종 검토해야 합니다.
- **약속 보수성**: "100% 안전" 같은 보장은 사용하지 않았으며, 모든 SLA (72시간 삭제, 7일/14일 환불 검토 등) 는 구현이 보장되는 한도로만 명시했습니다. 구현 검증 후 필요 시 수치 조정.
- **언어 동등성**: 한국어/영어 본문이 동등 유효임을 명시했으나, 정확한 번역 일치는 추가 교차 검토 필요.
