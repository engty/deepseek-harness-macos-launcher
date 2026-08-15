#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
SIGNING_MODE="${DEEPSEEK_HARNESS_SIGNING_MODE:-adhoc}"
SIGNING_IDENTITY="${DEEPSEEK_HARNESS_SIGNING_IDENTITY:-}"
ENTITLEMENTS_PATH="${DEEPSEEK_HARNESS_ENTITLEMENTS:-}"

fail() {
  echo "App signing failed: $*" >&2
  exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "usage: sign_app_bundle.sh <path-to-app>"
[[ -d "$APP_BUNDLE" ]] || fail "missing app bundle: $APP_BUNDLE"

case "$SIGNING_MODE" in
  adhoc)
    SIGN_ARGS=(--force --sign -)
    ;;
  developer-id)
    [[ -n "$SIGNING_IDENTITY" ]] || fail \
      "DEEPSEEK_HARNESS_SIGNING_IDENTITY is required for developer-id signing"
    [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || fail \
      "signing identity must start with 'Developer ID Application:'"
    security find-identity -v -p codesigning 2>/dev/null |
      grep -Fq "\"$SIGNING_IDENTITY\"" || fail \
      "signing identity is not available in the current keychain: $SIGNING_IDENTITY"
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
    ;;
  *)
    fail "unsupported signing mode '$SIGNING_MODE' (expected adhoc or developer-id)"
    ;;
esac

sign_path() {
  local path="$1"
  if [[ -n "$ENTITLEMENTS_PATH" ]]; then
    codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$path"
  else
    codesign "${SIGN_ARGS[@]}" "$path"
  fi
}

# Sign nested Mach-O files before sealing the outer bundle. This avoids relying
# on --deep for signing while still covering a bundled Node executable or
# future native helper added under Contents/.
while IFS= read -r -d '' candidate; do
  [[ "$candidate" == "$APP_BUNDLE/Contents/MacOS/HarnessLauncher" ]] && continue
  if file "$candidate" 2>/dev/null | grep -q 'Mach-O'; then
    sign_path "$candidate"
  fi
done < <(find "$APP_BUNDLE/Contents" -type f -perm -111 -print0)

sign_path "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  details="$(codesign -dvvv "$APP_BUNDLE" 2>&1 || true)"
  grep -Eq 'Authority=Developer ID Application:' <<<"$details" || fail \
    "bundle is not signed by Developer ID Application"
  grep -Eq 'flags=.*runtime' <<<"$details" || fail \
    "Developer ID bundle is missing Hardened Runtime"
fi

echo "App signing passed ($SIGNING_MODE): $APP_BUNDLE"
