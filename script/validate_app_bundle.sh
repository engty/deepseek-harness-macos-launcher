#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$ROOT_DIR/dist/HarnessLauncher.app}"
REQUIRE_BUNDLED_RUNTIME="${REQUIRE_BUNDLED_RUNTIME:-0}"

APP_CONTENTS="$APP_BUNDLE/Contents"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_CONTENTS/MacOS/HarnessLauncher"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RUNTIME_ROOT="$APP_RESOURCES/runtime"
PLUGIN_HELPER="$APP_RESOURCES/bin/deepseek-harness-plugin"

fail() {
  echo "Bundle validation failed: $*" >&2
  exit 1
}

[[ -d "$APP_BUNDLE" ]] || fail "missing app bundle: $APP_BUNDLE"
[[ -x "$APP_BINARY" ]] || fail "missing executable: $APP_BINARY"
[[ -f "$INFO_PLIST" ]] || fail "missing Info.plist"
[[ -f "$APP_RESOURCES/AppIcon.icns" ]] || fail "missing AppIcon.icns"
[[ -x "$PLUGIN_HELPER" ]] || fail "missing plugin helper CLI"

bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$bundle_name" == "DeepSeek Harness" ]] || fail "CFBundleDisplayName must be DeepSeek Harness"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$bundle_id" == "com.harness.desktop.launcher" ]] || fail "unexpected bundle identifier: $bundle_id"

codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$REQUIRE_BUNDLED_RUNTIME" == "1" || -d "$RUNTIME_ROOT" ]]; then
  [[ -d "$RUNTIME_ROOT" ]] || fail "bundled Runtime is required but missing"
  [[ -x "$RUNTIME_ROOT/node_modules/.bin/dsh" || -x "$RUNTIME_ROOT/bin/dsh" || -x "$RUNTIME_ROOT/dsh" ]] \
    || fail "bundled Runtime has no executable dsh"
  [[ -x "$RUNTIME_ROOT/node_modules/.bin/pnpm" ]] \
    || fail "bundled Runtime has no executable pnpm"
  if [[ -e "$RUNTIME_ROOT/node" ]]; then
    [[ -x "$RUNTIME_ROOT/node/bin/node" ]] || fail "bundled Node is present but not executable"
  fi
fi

echo "Bundle validation passed: $APP_BUNDLE"
