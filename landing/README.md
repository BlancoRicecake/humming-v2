# Humming — 랜딩 페이지

`humming-UI.pen`의 랜딩 페이지 디자인을 그대로 옮긴 **독립 정적 사이트**입니다.
빌드·프레임워크·서버 없이 동작하며, 어디에나 그대로 배포할 수 있습니다.

---

## 빠르게 보기

- **그냥 열기**: `index.html` 더블클릭 → 기본 브라우저에서 바로 열림 (`file://`)
- **로컬 서버**(모바일 기기에서 같은 와이파이로 확인할 때 권장):
  ```bash
  cd landing
  python -m http.server 5500
  # → http://localhost:5500
  ```

---

## 폴더 구조

```
landing/
├─ index.html        # 마크업 + 콘텐츠(한글 카피) + 스크롤 리빌 스크립트
├─ styles.css        # 디자인 토큰 · 레이아웃 · 애니메이션 · 반응형
├─ README.md         # 이 문서
└─ assets/
   ├─ logo.png         # 라임 종이접기 벌새 로고 (네비/가입/다운로드/푸터 공용)
   └─ app-screen.png   # 히어로의 앱 화면 (배경 정리 완료본)
```

> 의존성 없음. 외부 리소스는 **Google Fonts(Inter)** 하나뿐이며, 미로딩 시 시스템 폰트로 자연스럽게 대체됩니다.

---

## 섹션 구성 (위 → 아래)

| 섹션 | 내용 | 비고 |
|------|------|------|
| **Navbar** | 로고 + `기능` / `다운로드` / `시작하기`(라임 CTA) | sticky, 스크롤 시 배경 블러 |
| **Hero** | 배지, `흥얼거리면, 음악이 됩니다.`, 서브카피, CTA 2개, 신뢰 문구 + 폰 이미지 | 2단 → 모바일 1단 |
| **Features** | `WHY HUMMING` + 제목 + 3카드(흥얼거림→트랙 / 키·베이스·드럼·보컬 / 완전한 오프라인) | 3열 그리드 |
| **Vision** | `누구나 즐길 수 있습니다.` + 철학 본문 + 2카드 | 라디얼 그린 그라데이션 배경 |
| **Signup** | 가입 카드 + 소셜 버튼(Google / Apple / Kakao) | 버튼은 현재 **시각 목업** |
| **Download** | 로고(글로우) + 제목 + App Store / Google Play 배지 | 배지 = `Coming soon` |
| **Footer** | 로고 · `© 2026` + 이용약관 / 개인정보처리방침 / 문의 | |

### 내비게이션 앵커
- `기능` → `#features`
- `다운로드` → `#download`
- `시작하기` · `무료로 시작하기` → `#signup`
- `앱 다운로드` → `#download`

---

## 디자인 토큰

`styles.css` 상단 `:root`에 모두 정의되어 있습니다. 색/폰트/간격을 바꾸려면 여기만 수정하면 전체에 반영됩니다.

| 토큰 | 값 | 용도 |
|------|------|------|
| `--bg` | `#0A0A0F` | 페이지 배경 |
| `--bg-section` | `#0C0C13` | Features · Download 배경 |
| `--card` | `#131318` | 카드 배경 |
| `--border` / `--border-soft` | `#1F1F27` / `#27272A` | 테두리 |
| `--lime` | `#A3E635` | 강조색(브랜드) |
| `--chip-bg` | `#1C2A0E` | 아이콘 칩 배경 |
| `--text` / `--text-2` / `--text-3` / `--text-4` | `#FAFAFA` / `#A1A1AA` / `#71717A` / `#52525B` | 텍스트 단계 |
| `--font` | Inter + 시스템 한글 폴백 | 본문 폰트 |
| `--maxw` | `1280px` | 콘텐츠 최대 폭 |
| `--pad-x` | `clamp(20px, 5vw, 64px)` | 좌우 여백 |

- **아이콘**: 외부 라이브러리 없이 전부 **인라인 SVG**. UI 아이콘은 스트로크 스타일, 브랜드 로고(Google·Apple·Kakao·Play)는 정식 패스. → 오프라인에서도 깨지지 않음.

---

## 애니메이션

`styles.css`의 `@media (prefers-reduced-motion: no-preference)` 블록 + `index.html` 하단의 `IntersectionObserver` 스크립트로 구현.

**로드 시**
- 네비바 드롭인
- 히어로 요소 순차 페이드업(stagger), 폰 이미지 지연 등장

**상시(루프)**
- 폰 화면 부유(float, 6s)
- 배지 점 펄스

**스크롤 시(리빌)** — 화면에 들어올 때 페이드업, 카드 그룹은 0.1s씩 시차
- 적용 대상: `.reveal`(단일 요소), `.reveal-group` + `.reveal-item`(시차 그룹)

**호버**
- 카드 hover 시 아이콘 칩 lift/확대, 버튼 lift + 라임 글로우

**접근성 / 견고성**
- `prefers-reduced-motion: reduce` 사용자에겐 모션 전부 비활성, 콘텐츠는 처음부터 표시(숨김 없음)
- IntersectionObserver 미지원/비활성 시 전체 즉시 표시 → JS 없이도 안전
- transform·opacity만 사용(`will-change` 지정), 외부 라이브러리 0

---

## 흔한 수정 가이드

- **카피 변경**: `index.html`에서 해당 한글 텍스트 직접 수정
- **색/폰트/여백**: `styles.css`의 `:root` 토큰 수정
- **앱 화면 교체**: `assets/app-screen.png` 교체 (권장 비율 **756 : 1568** = 폰 프레임과 동일, 다른 비율이면 상하 잘림)
- **로고 교체**: `assets/logo.png` 교체 (정사각 권장)
- **새 리빌 요소**: 단일은 `class="... reveal"`, 시차 그룹은 부모에 `reveal-group` + 자식에 `reveal-item`
- **애니메이션 끄기**: `styles.css`의 `@media (prefers-reduced-motion: no-preference)` 블록 제거 또는 비우기

---

## 알아둘 점 / 후속 작업 후보

- 소셜 로그인 버튼과 스토어 배지는 **시각 목업**입니다. 실제 동작하려면 OAuth 연동 / 스토어 링크 필요.
- 푸터 링크(이용약관·개인정보처리방침·문의)는 `#` placeholder.
- 폰트를 완전 오프라인으로 쓰려면 Inter를 self-host로 전환(현재는 Google Fonts CDN).
- 추가 가능 효과: 마우스 틸트(parallax), 숫자 카운트업, 히어로 배경 라임 글로우 흐름 등.

---

## 원본 디자인

- 디자인 소스: `C:\Users\jlion\Desktop\Humming\design\humming-UI.pen` — `Landing Page` 프레임(`AmBaD`)
- 이 사이트는 해당 디자인을 코드로 충실히 재현한 결과물입니다.
