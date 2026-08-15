#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$ROOT_DIR/dist/HarnessLauncher.app}"

REQUIRE_BUNDLED_RUNTIME=1 "$ROOT_DIR/script/validate_app_bundle.sh" "$APP_BUNDLE"
swift -e 'import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: url)
_ = try JSONSerialization.jsonObject(with: data)
' "$ROOT_DIR/compatibility-matrix.json"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "${DEEPSEEK_HARNESS_SIGNING_MODE:-adhoc}" == "developer-id" ]]; then
  signing_details="$(codesign -dvvv "$APP_BUNDLE" 2>&1 || true)"
  grep -Eq 'Authority=Developer ID Application:' <<<"$signing_details" \
    || { echo "Release validation failed: missing Developer ID Application signature" >&2; exit 1; }
  grep -Eq 'flags=.*runtime' <<<"$signing_details" \
    || { echo "Release validation failed: missing Hardened Runtime" >&2; exit 1; }
  echo "Developer ID Application and Hardened Runtime were verified."
else
  echo "Ad-hoc bundle integrity was verified; Developer ID and notarization were not requested."
fi

echo "Release validation passed: $APP_BUNDLE"
