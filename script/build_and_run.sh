#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HarnessLauncher"
BUNDLE_ID="com.harness.desktop.launcher"
MIN_SYSTEM_VERSION="13.0"
APP_VERSION="${APP_VERSION:-0.1.0-dev}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
BUILD_BUNDLE="$DIST_DIR/$APP_NAME.app.build-$$"
APP_CONTENTS="$BUILD_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
DISCOUNT_ICON_SOURCE="$ROOT_DIR/Resources/DiscountIcon.svg"
ICONSET_DIR="$DIST_DIR/DeepSeekHarness.$$.iconset"
ICON_FILE="$APP_RESOURCES/AppIcon.icns"
PLUGIN_HELPER_SOURCE="$ROOT_DIR/script/deepseek-harness-plugin"
PLUGIN_HELPER_DESTINATION="$APP_RESOURCES/bin/deepseek-harness-plugin"

# APP_VERSION is embedded into the Info.plist XML: reject characters that
# would produce an invalid plist instead of breaking the build later.
if [[ ! "$APP_VERSION" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  echo "APP_VERSION 包含非法字符（只允许 A-Za-z0-9 . _ + -）：$APP_VERSION" >&2
  exit 2
fi

# Single-writer build lock: two concurrent runs used to interleave writes
# into the same bundle. Never removed automatically.
mkdir -p "$DIST_DIR"
BUILD_LOCK="$DIST_DIR/.build-lock"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
  echo "另一个构建正在运行（或存在陈旧锁目录 ${BUILD_LOCK}）。确认没有并发构建后可手动删除该目录。" >&2
  exit 2
fi
trap 'rm -rf "$BUILD_BUNDLE" "$ICONSET_DIR"; rmdir "$BUILD_LOCK" 2>/dev/null || true' EXIT

# Gracefully quit a running instance of THIS app by bundle id instead of
# killing processes by name. Set HARNESS_SKIP_APP_QUIT=1 when the current
# session itself runs inside the app (or in CI, where nothing is running).
if [[ "${HARNESS_SKIP_APP_QUIT:-0}" != "1" ]]; then
  osascript -e 'tell application id "com.harness.desktop.launcher" to quit' 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

BUILD_BIN_DIR="$(swift build --configuration debug --show-bin-path)"
swift build --configuration debug
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"

rm -rf "$BUILD_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -d "$ROOT_DIR/Resources/runtime" ]]; then
  cp -R "$ROOT_DIR/Resources/runtime" "$APP_RESOURCES/runtime"
fi
cp -R "$ROOT_DIR/Resources/dsh1024-launcher" "$APP_RESOURCES/dsh1024-launcher"
if [[ -x "$PLUGIN_HELPER_SOURCE" ]]; then
  mkdir -p "$(dirname "$PLUGIN_HELPER_DESTINATION")"
  cp "$PLUGIN_HELPER_SOURCE" "$PLUGIN_HELPER_DESTINATION"
  chmod +x "$PLUGIN_HELPER_DESTINATION"
fi
if [[ -f "$DISCOUNT_ICON_SOURCE" ]]; then
  cp "$DISCOUNT_ICON_SOURCE" "$APP_RESOURCES/DiscountIcon.svg"
fi

if [[ -f "$ICON_SOURCE" ]]; then
  command -v sips >/dev/null
  command -v iconutil >/dev/null
  mkdir -p "$ICONSET_DIR"
  for size in 16 32 128 256 512; do
    double_size=$((size * 2))
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
  rm -rf "$ICONSET_DIR"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>DeepSeek Harness</string>
  <key>CFBundleDisplayName</key>
  <string>DeepSeek Harness</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

RUNTIME_NODE="$APP_RESOURCES/runtime/node/bin/node"
DEEPSEEK_HARNESS_SIGNING_MODE="${DEEPSEEK_HARNESS_SIGNING_MODE:-adhoc}" \
  DEEPSEEK_HARNESS_SIGNING_IDENTITY="${DEEPSEEK_HARNESS_SIGNING_IDENTITY:-}" \
  DEEPSEEK_HARNESS_ENTITLEMENTS="${DEEPSEEK_HARNESS_ENTITLEMENTS:-}" \
  "$ROOT_DIR/script/sign_app_bundle.sh" "$BUILD_BUNDLE"
REQUIRE_BUNDLED_RUNTIME="${REQUIRE_BUNDLED_RUNTIME:-0}" \
  "$ROOT_DIR/script/validate_app_bundle.sh" "$BUILD_BUNDLE"

# Only swap the validated bundle into place; the final path never holds a
# half-built bundle.
rm -rf "$APP_BUNDLE"
mv "$BUILD_BUNDLE" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --build-only|build-only)
    echo "App bundle built and validated: $APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
