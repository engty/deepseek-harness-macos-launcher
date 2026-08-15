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
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$DIST_DIR/DeepSeekHarness.iconset"
ICON_FILE="$APP_RESOURCES/AppIcon.icns"
PLUGIN_HELPER_SOURCE="$ROOT_DIR/script/deepseek-harness-plugin"
PLUGIN_HELPER_DESTINATION="$APP_RESOURCES/bin/deepseek-harness-plugin"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --configuration debug
BUILD_BINARY="$(swift build --configuration debug --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -d "$ROOT_DIR/Resources/runtime" ]]; then
  cp -R "$ROOT_DIR/Resources/runtime" "$APP_RESOURCES/runtime"
fi
if [[ -x "$PLUGIN_HELPER_SOURCE" ]]; then
  mkdir -p "$(dirname "$PLUGIN_HELPER_DESTINATION")"
  cp "$PLUGIN_HELPER_SOURCE" "$PLUGIN_HELPER_DESTINATION"
  chmod +x "$PLUGIN_HELPER_DESTINATION"
fi

if [[ -f "$ICON_SOURCE" ]]; then
  command -v sips >/dev/null
  command -v iconutil >/dev/null
  rm -rf "$ICONSET_DIR"
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
if [[ -x "$RUNTIME_NODE" ]]; then
  codesign --force --sign - "$RUNTIME_NODE"
fi
# The product deliberately ships through a controlled channel without
# Developer ID/notarization. Ad-hoc signing still gives local builds a sealed
# resource map and lets the bundle pass deterministic integrity checks.
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
REQUIRE_BUNDLED_RUNTIME="${REQUIRE_BUNDLED_RUNTIME:-0}" \
  "$ROOT_DIR/script/validate_app_bundle.sh" "$APP_BUNDLE"

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
