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

echo "Developer ID and Apple notarization are outside this product scope; ad-hoc bundle integrity was verified."

echo "Release validation passed: $APP_BUNDLE"
