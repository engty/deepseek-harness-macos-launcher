#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${1:-${HARNESS_RUNTIME_SOURCE:-}}"
NODE_PATH="${HARNESS_NODE_PATH:-$(command -v node || true)}"
DESTINATION="$ROOT_DIR/Resources/runtime"

if [[ -z "$SOURCE_ROOT" || ! -d "$SOURCE_ROOT" ]]; then
  echo "usage: HARNESS_RUNTIME_SOURCE=/path/to/runtime HARNESS_NODE_PATH=/path/to/node $0" >&2
  exit 2
fi
if [[ -z "$NODE_PATH" || ! -x "$NODE_PATH" ]]; then
  echo "没有找到可执行 Node；请设置 HARNESS_NODE_PATH。" >&2
  exit 2
fi

if [[ -f "$SOURCE_ROOT/node_modules/.bin/dsh" ]]; then
  RUNTIME_SOURCE="$SOURCE_ROOT"
elif [[ -f "$SOURCE_ROOT/.bin/dsh" ]]; then
  RUNTIME_SOURCE=""
else
  echo "Runtime source 中没有 node_modules/.bin/dsh。" >&2
  exit 2
fi

STAGING_ROOT="$(mktemp -d -t deepseek-harness-runtime)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
mkdir -p "$STAGING_ROOT/runtime/node/bin"

if [[ -n "$RUNTIME_SOURCE" ]]; then
  ditto "$RUNTIME_SOURCE" "$STAGING_ROOT/runtime"
else
  mkdir -p "$STAGING_ROOT/runtime/node_modules"
  ditto "$SOURCE_ROOT" "$STAGING_ROOT/runtime/node_modules"
fi
cp "$NODE_PATH" "$STAGING_ROOT/runtime/node/bin/node"
chmod +x "$STAGING_ROOT/runtime/node/bin/node"

if [[ -e "$DESTINATION" ]]; then
  BACKUP="$DESTINATION.backup.$(date +%Y%m%d-%H%M%S)"
  mv "$DESTINATION" "$BACKUP"
  echo "已有 Runtime 已保留到：$BACKUP"
fi
mv "$STAGING_ROOT/runtime" "$DESTINATION"
echo "Runtime 已写入：$DESTINATION"
