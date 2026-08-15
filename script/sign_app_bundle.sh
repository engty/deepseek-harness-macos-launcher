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
# future native helper added under Contents/. All regular files are classified
# in a SINGLE `file` invocation (the bundle contains tens of thousands of
# runtime files; spawning `file` per file would take minutes), so dylibs and
# frameworks without the execute bit are covered too.
file_list="$(mktemp -t dsh-sign-files.XXXXXX)"
cleanup_file_list() { rm -f "$file_list"; }
trap cleanup_file_list EXIT
find "$APP_BUNDLE/Contents" -type f -print0 >"$file_list" || fail "cannot enumerate bundle contents"
if [[ ! -s "$file_list" ]]; then
  fail "bundle contains no files to scan"
fi
# `file -0 -f -` emits "<path>\0<description>\n" pairs for NUL-terminated
# input paths; read them as matched pairs.
while IFS= read -r -d '' candidate; do
  IFS= read -r description || true
  [[ "$candidate" == "$APP_BUNDLE/Contents/MacOS/HarnessLauncher" ]] && continue
  case "$description" in
    *Mach-O*)
      sign_path "$candidate"
      ;;
  esac
done < <(file -0 -f - <"$file_list")

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
