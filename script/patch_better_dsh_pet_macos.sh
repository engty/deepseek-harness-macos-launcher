#!/usr/bin/env bash
set -euo pipefail

# Apply the reviewed macOS adapter to the npm package fetched during Runtime
# assembly. The package itself stays the upstream DSH bundle; only platform
# files are replaced. This keeps the normal `dsh plugin` contract intact.
if [[ "$(uname -s)" != "Darwin" ]]; then
  exit 0
fi

PACKAGE_ROOT="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER_ROOT="$ROOT_DIR/Resources/better-dsh-pet-macos"

if [[ -z "$PACKAGE_ROOT" || ! -d "$PACKAGE_ROOT" ]]; then
  echo "better-dsh-pet 包目录不存在：$PACKAGE_ROOT" >&2
  exit 2
fi

for required in \
  "$ADAPTER_ROOT/lib/index.js" \
  "$ADAPTER_ROOT/lib/pet-helper-process.js" \
  "$ADAPTER_ROOT/runtime/electron-helper/main.js" \
  "$ADAPTER_ROOT/runtime/electron-helper/preload.js" \
  "$ADAPTER_ROOT/runtime/electron-helper/renderer.js" \
  "$ADAPTER_ROOT/scripts/ensure-electron.mjs" \
  "$ADAPTER_ROOT/cordis.patch.yml"; do
  [[ -f "$required" ]] || {
    echo "macOS 桌宠适配文件缺失：$required" >&2
    exit 2
  }
done

PACKAGE_VERSION="$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.version || "")' "$PACKAGE_ROOT/package.json")"
if [[ "$PACKAGE_VERSION" != "0.3.5" ]]; then
  echo "better-dsh-pet 版本不匹配：需要 0.3.5，实际为 $PACKAGE_VERSION" >&2
  exit 1
fi

mkdir -p "$PACKAGE_ROOT/lib" "$PACKAGE_ROOT/runtime/electron-helper" "$PACKAGE_ROOT/scripts"
cp "$ADAPTER_ROOT/lib/index.js" "$PACKAGE_ROOT/lib/index.js"
cp "$ADAPTER_ROOT/lib/pet-helper-process.js" "$PACKAGE_ROOT/lib/pet-helper-process.js"
cp "$ADAPTER_ROOT/runtime/electron-helper/main.js" "$PACKAGE_ROOT/runtime/electron-helper/main.js"
cp "$ADAPTER_ROOT/runtime/electron-helper/preload.js" "$PACKAGE_ROOT/runtime/electron-helper/preload.js"
cp "$ADAPTER_ROOT/runtime/electron-helper/renderer.js" "$PACKAGE_ROOT/runtime/electron-helper/renderer.js"
cp "$ADAPTER_ROOT/scripts/ensure-electron.mjs" "$PACKAGE_ROOT/scripts/ensure-electron.mjs"
cp "$ADAPTER_ROOT/cordis.patch.yml" "$PACKAGE_ROOT/cordis.patch.yml"

# The upstream settings panel owns its range input in lib/client.js instead of
# deriving it from the server schema. Keep that UI bound to the same 40%-120%
# contract; fail closed if the pinned upstream source changes unexpectedly.
CLIENT_FILE="$PACKAGE_ROOT/lib/client.js"
if [[ ! -f "$CLIENT_FILE" ]]; then
  echo "better-dsh-pet 配置面板文件缺失：$CLIENT_FILE" >&2
  exit 2
fi
/usr/bin/perl -0pi -e "s/type: 'range', min: 0\\.8, max: 1\\.2/type: 'range', min: 0.4, max: 1.2/" "$CLIENT_FILE"
/usr/bin/perl -0pi -e 's/气泡大小（0\.8～1\.2）/气泡大小（0.4～1.2）/g; s/气泡大小（80%～120%）/气泡大小（40%～120%）/g' \
  "$PACKAGE_ROOT/lib/types/index.d.ts" "$PACKAGE_ROOT/README.md" 2>/dev/null || true
if ! grep -Fq "type: 'range', min: 0.4, max: 1.2" "$CLIENT_FILE"; then
  echo "better-dsh-pet 配置面板滑块未成功设置为 40% 下限。" >&2
  exit 1
fi

echo "已应用 better-dsh-pet macOS 适配：$PACKAGE_ROOT"
