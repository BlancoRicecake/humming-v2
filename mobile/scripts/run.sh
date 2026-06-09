#!/usr/bin/env bash
# debug 빌드용 flutter run 래퍼 — backend/.env.secrets 의 키들을
# --dart-define 로 자동 주입한다. 미주입 시 앱이 "Sign-in is not
# configured" 같은 에러를 띄움 (Supabase 키 미설정 → auth 비활성).
#
# 사용:
#   mobile/scripts/run.sh                       # 기본 (iOS sim 자동 선택)
#   mobile/scripts/run.sh -d <device-id>        # 특정 디바이스 지정
#   mobile/scripts/run.sh --release             # release 모드 (서명 없는 로컬 실행)
#   mobile/scripts/run.sh --profile             # profile 모드
#
# 출시 빌드는 fastlane (mobile/{ios,android}/fastlane) 가 같은 키를 주입.
# 이 스크립트는 debug 전용.
set -euo pipefail

# 스크립트 위치 → repo 루트 추정 (mobile/scripts → mobile → repo).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MOBILE_DIR/.." && pwd)"
SECRETS="$REPO_ROOT/backend/.env.secrets"

if [[ ! -f "$SECRETS" ]]; then
  echo "[run.sh] backend/.env.secrets 없음: $SECRETS" >&2
  echo "[run.sh] .env.secrets.example 참고해서 SUPABASE_URL / SUPABASE_ANON_KEY /" >&2
  echo "[run.sh] GOOGLE_OAUTH_CLIENT_ID / ENGINE_URL 채워두세요." >&2
  exit 1
fi

# .env.secrets 의 key=value 추출 (주석/빈줄 무시, 따옴표 제거).
read_env() {
  local key="$1"
  grep -E "^${key}=" "$SECRETS" 2>/dev/null \
    | tail -1 \
    | sed -E "s/^${key}=//; s/^['\"]//; s/['\"]$//"
}

# Fastfile 과 동일한 키 셋. GOOGLE_WEB_CLIENT_ID 가 비었으면 GOOGLE_OAUTH_CLIENT_ID 폴백.
SUPABASE_URL_VAL="$(read_env SUPABASE_URL)"
SUPABASE_ANON_KEY_VAL="$(read_env SUPABASE_ANON_KEY)"
GOOGLE_WEB_CLIENT_ID_VAL="$(read_env GOOGLE_WEB_CLIENT_ID)"
[[ -z "$GOOGLE_WEB_CLIENT_ID_VAL" ]] && GOOGLE_WEB_CLIENT_ID_VAL="$(read_env GOOGLE_OAUTH_CLIENT_ID)"
ENGINE_URL_VAL="$(read_env ENGINE_URL)"

DEFINES=()
[[ -n "$SUPABASE_URL_VAL" ]] && DEFINES+=("--dart-define=SUPABASE_URL=$SUPABASE_URL_VAL")
[[ -n "$SUPABASE_ANON_KEY_VAL" ]] && DEFINES+=("--dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY_VAL")
[[ -n "$GOOGLE_WEB_CLIENT_ID_VAL" ]] && DEFINES+=("--dart-define=GOOGLE_WEB_CLIENT_ID=$GOOGLE_WEB_CLIENT_ID_VAL")
[[ -n "$ENGINE_URL_VAL" ]] && DEFINES+=("--dart-define=ENGINE_URL=$ENGINE_URL_VAL")

echo "[run.sh] dart-defines: ${#DEFINES[@]} keys injected"
for d in "${DEFINES[@]}"; do
  # 값 마스킹 — KEY 만 출력.
  echo "  ${d%%=*}=***"
done

cd "$MOBILE_DIR"
exec flutter run "${DEFINES[@]}" "$@"
