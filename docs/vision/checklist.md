# HumTrack 로드맵 체크리스트

기준 문서: [`VISION-ROADMAP.md`](VISION-ROADMAP.md) · 시작일: 2026-10-12

## Phase 0 — 기반 다지기

- [ ] 브랜치 현황 표 만들기 (`git branch -a`, 각 브랜치의 main 대비 ahead/behind, 스토어에 나간 커밋)
- [ ] 출시 기준 브랜치 하나 정하고 미병합 브랜치(songplan, guided-creation, login-hotfix, fix/ios-firebase-plist) 병합 순서 결정
- [ ] 현재 스토어 공개 버전 확인 (iOS 1.0.10(39) 심사 결과, Android 프로덕션 롤백 이후 상태)
- [ ] 모바일 Sentry 테스트 이벤트를 Android·iOS 실기기에서 각각 수신 확인
- [ ] Clarity iOS 세션이 1.0.10 이후 복구됐는지 확인
- [ ] Firebase 게이트 1 — 개인정보처리방침 1.4 고지 일정 확인 (10-02 고지 마감을 놓쳤으면 시행일 이동)
- [ ] Firebase 게이트 2 — App Store Privacy / Play Data safety 제출
- [ ] Firebase 게이트 3 — 보존기간 2개월, Google Signals·광고 개인화 off 확인
- [ ] Firebase 게이트 4 — 스테이징 빌드로 DebugView 이벤트 실기기 검증
- [ ] Firebase 게이트 5·6 — 프로덕션 define 설정 후 수집 활성화
- [ ] 첫 곡 퍼널 대시보드 (app_started → recording_started → analyze_completed → guided_song_saved)
- [ ] ✅ 완료 기준: 기준 브랜치에서 양 플랫폼 빌드 + 퍼널 1주치 데이터

## Phase 1 — 3분 안에 첫 곡

- [ ] guided 흐름이 기준 브랜치에 병합·출시됐는지 확인
- [ ] 첫 실행 기본 경로를 guided로 (신규 사용자만)
- [ ] 초보자 5명 관찰 세션 준비 (과제 문장, 화면 녹화 방법, 기록 양식)
- [ ] 관찰 1회차 진행·막힘 지점 기록
- [ ] 막힘 지점 수정 후 관찰 2회차
- [ ] ✅ 완료 기준: 5명 중 4명이 3분 안에 첫 곡 저장 + 최대 이탈 단계 특정

## Phase 2 — "내가 부른 멜로디가 맞다"

- [ ] 허밍 평가 세트 수집 동의서·수집 방법 정하기
- [ ] 튜닝용/확인용 분리, 정답 라벨과 허용 오차 정의
- [ ] 현재 pYIN 경로 기준선 측정 (음정·옥타브·누락·과분할·타이밍)
- [ ] 오류 유형별 개선 → 확인용 세트로 재측정
- [ ] ✅ 완료 기준: 기준선 대비 개선 수치 + 수동 수정 횟수 감소

## 데스크톱 트랙 (병행)

- [ ] desktop 브랜치에 빠진 출시 커밋 확인 (songplan, login-hotfix, fix/ios-firebase-plist) — Phase 0 브랜치 정리와 같이
- [ ] 데스크톱 결제 방식 결정 (A 모바일 구독 계정 연동 / B 무료 프리뷰 / C 별도 결제)
- [ ] D1 최신 기준 브랜치로 Windows 프리뷰 재빌드·스모크 테스트
- [ ] D2 데스크톱 OAuth 콜백 등록 (Supabase redirect, `humtrack://auth/callback` 프로토콜 처리)
- [ ] D2 계정 기반 Pro 권한이 데스크톱에서 열리는지 확인
- [ ] D2 실제 USB/내장 마이크로 허밍 녹음·변환·지연 확인
- [ ] D3 Windows 코드 서명·설치 프로그램
- [ ] D3 깨끗한 Windows PC에서 설치부터 첫 곡까지 검증
- [ ] D3 `hum-track.com` 다운로드·FAQ 갱신
- [ ] D4 Mac에서 빌드·소리·마이크·로그인·내보내기 검증 (`MAC-HANDOFF-2026-09-18.md` 6장)
- [ ] D4 Developer ID 서명·공증 프리뷰
- [ ] ✅ 완료 기준: 깨끗한 Windows PC에서 설치 → 로그인 → 첫 곡 → 저장 → 재실행 → 내보내기

## Phase 3 — 완성하고 들려주기

- [ ] 무료 "들려주기" 정책 결정 (A/B/C, `VISION-ROADMAP.md` 4장)
- [ ] 결정안 구현
- [ ] ✅ 완료 기준: 두 번째 곡 비율 상승
