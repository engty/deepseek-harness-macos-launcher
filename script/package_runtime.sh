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

if [[ -n "$RUNTIME_SOURCE" ]]; then
  [[ -x "$SOURCE_ROOT/node_modules/.bin/pnpm" ]] || {
    echo "Runtime source 中没有 node_modules/.bin/pnpm；请把固定版本 pnpm 一起安装到 Runtime。" >&2
    exit 2
  }
else
  [[ -x "$SOURCE_ROOT/.bin/pnpm" ]] || {
    echo "Runtime source 中没有 .bin/pnpm；请把固定版本 pnpm 一起安装到 Runtime。" >&2
    exit 2
  }
fi

# Single-writer lock: two concurrent packaging runs used to race on the
# destination and the backup name. The lock is never removed automatically.
LOCK_DIR="$ROOT_DIR/Resources/.runtime-lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "另一个 Runtime 打包正在运行（或存在陈旧锁目录 $LOCK_DIR）。确认没有并发运行后可手动删除该目录。" >&2
  exit 2
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Same-volume staging under Resources so the final move is an atomic rename
# (system TMPDIR can live on another volume).
STAGING_ROOT="$ROOT_DIR/Resources/.runtime-staging.$$"
BACKUP=""
trap 'rm -rf "$STAGING_ROOT"; if [[ -n "$BACKUP" && ! -d "$DESTINATION" && -d "$BACKUP" ]]; then mv "$BACKUP" "$DESTINATION" 2>/dev/null || true; fi; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

mkdir -p "$STAGING_ROOT/runtime/node/bin"

if [[ -n "$RUNTIME_SOURCE" ]]; then
  ditto "$RUNTIME_SOURCE" "$STAGING_ROOT/runtime"
else
  mkdir -p "$STAGING_ROOT/runtime/node_modules"
  ditto "$SOURCE_ROOT" "$STAGING_ROOT/runtime/node_modules"
fi
cp "$NODE_PATH" "$STAGING_ROOT/runtime/node/bin/node"
chmod +x "$STAGING_ROOT/runtime/node/bin/node"

# The bundled Node must actually run before it can be shipped.
NODE_VERSION_OUTPUT="$("$STAGING_ROOT/runtime/node/bin/node" --version 2>&1)" || {
  echo "内置 Node 无法运行：$NODE_VERSION_OUTPUT" >&2
  exit 1
}
[[ "$NODE_VERSION_OUTPUT" =~ ^v[0-9]+ ]] || {
  echo "内置 Node 版本输出异常：$NODE_VERSION_OUTPUT" >&2
  exit 1
}
echo "内置 Node 探针通过：$NODE_VERSION_OUTPUT"

if [[ -e "$DESTINATION" ]]; then
  BACKUP="$DESTINATION.backup.$(date +%Y%m%d-%H%M%S)-$$"
  mv "$DESTINATION" "$BACKUP"
  echo "已有 Runtime 已保留到：$BACKUP"
fi

if ! mv "$STAGING_ROOT/runtime" "$DESTINATION"; then
  echo "新 Runtime 落位失败，正在恢复旧 Runtime。" >&2
  if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
    mv "$BACKUP" "$DESTINATION" 2>/dev/null || echo "警告：旧 Runtime 恢复也失败，请手动从 $BACKUP 恢复。" >&2
  fi
  exit 1
fi
rm -rf "$STAGING_ROOT"
BACKUP=""
echo "Runtime 已写入：$DESTINATION"
