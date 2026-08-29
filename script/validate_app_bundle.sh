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
    node_version="$("$RUNTIME_ROOT/node/bin/node" --version 2>&1)" \
      || fail "bundled Node does not run: $node_version"
    [[ "$node_version" =~ ^v[0-9]+ ]] || fail "bundled Node version output is invalid: $node_version"
    node_semver="${node_version#v}"
    IFS=. read -r node_major node_minor _ <<< "$node_semver"
    if (( node_major < 22 || (node_major == 22 && node_minor < 19) )); then
      fail "bundled Node is too old: $node_version (requires at least v22.19.0)"
    fi
    echo "Bundled Node probe passed: $node_version"
    probe_home="$(mktemp -d)"
    trap 'rm -rf "$probe_home"' EXIT
    PATH="$RUNTIME_ROOT/node/bin:$PATH" DSH_HOME="$probe_home" \
      "$RUNTIME_ROOT/node_modules/.bin/dsh" --version >/dev/null 2>&1 \
      || fail "bundled dsh does not run against the bundled Node"
    echo "Bundled dsh probe passed."
  fi
fi

echo "Bundle validation passed: $APP_BUNDLE"
