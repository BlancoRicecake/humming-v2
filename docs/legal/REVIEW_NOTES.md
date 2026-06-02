**최종 갱신: 2026-06-02**
**대상: 외부 변호사 (한국 / 미국 / EU 자문)**

# 변호사 검토 시 챙겨야 할 포인트

본 메모는 `terms-of-service.md`, `privacy-policy.md`, `refund-policy.md` 1차 초안에 대해 출시 전 외부 자문 검토 시 우선 확인해 주셔야 할 항목입니다.

## 1. 운영 주체 확정 (모든 문서)
- `[PLACEHOLDER]` 로 비워둔 회사명·주소·사업자등록번호·대표자·DPO 명을 확정. 1인 개발자 단계라 개인사업자 → 추후 법인 전환 가능성. 약관 승계 조항 필요 여부 확인.

## 2. 미국 분쟁 해결 조항 (ToS 제9조)
- Arbitration clause / class action waiver 도입 여부. FAA 하에서는 일반적이나 캘리포니아 거주 소비자에 대한 enforceability (McGill rule 등) 검토 필요.
- "Santa Clara County" 가 1인 개발자에게 현실적인지 — 한국 거주 운영자라면 venue 를 다시 검토.

## 3. 한국 「전자상거래법」 청약철회권 (Refund 제3조)
- 디지털콘텐츠 사용 개시 시점의 정의. "분석 한 번 실행 = 사용 개시" 로 해석할지 명확히 할 것.
- 7일 무료 체험 → 자동 결제 직후 즉시 환불 가능 여부, 공정위 표준약관과의 정합성.

## 4. EU GDPR (Privacy 제4·5조)
- Supabase(us-east-1) 및 Cloudflare R2 로의 EU→US 데이터 이전 시 SCC 체결 여부 — 각 벤더의 DPA 검토 후 회사가 controller, 위 업체들이 processor 임을 약정.
- EU 대리인(Art. 27) 지정 의무 여부 — EU 거주자 대상 서비스이므로 필요할 가능성 큼. 단, 소규모 예외 적용 검토.

## 5. CCPA/CPRA (Privacy 제5조)
- "Do Not Sell or Share" 링크를 앱 내·웹 푸터에 노출해야 하는지. PostHog 익명 분석이 "share" 정의에 해당하는지 신중 검토 (SDK level cross-context behavioral advertising 여부).

## 6. Apple/Google IAP 약관과의 정합성
- App Store Review Guidelines 3.1.1 (외부 결제 유도 금지) 준수.
- Google Play Billing 정책 위반 소지 없는지 환불 정책 표현 점검.

## 7. 보컬 데이터 = "민감정보" 여부
- 한국 PIPA 상 음성은 일반적으로 민감정보가 아니지만, biometric 처리로 해석될 여지 검토. AI 학습 금지 명시는 이미 강력하나 추가 동의 절차 필요 여부 확인.

## 8. 만 14세 이슈
- 한국 PIPA: 만 14세 미만 법정대리인 동의. 미국 COPPA: 13세. EU: GDPR Art. 8 기본 16세(국가별 13~16). 가입 흐름에서 연령 확인 UI 설계 필요.

## 9. 약관 동의 UI
- Click-wrap (체크박스 + 명시 동의) 채택 권장. 한국 표준약관 공정위 기준 준수.

## 10. 향후 기능 추가 시 트리거
- 외부 공유 / Export to TikTok 등 외부 전송 기능 추가 시 본 약관 6조 라이선스 범위 재검토 필수.
