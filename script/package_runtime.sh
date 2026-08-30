#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${1:-${HARNESS_RUNTIME_SOURCE:-}}"
NODE_PATH="${HARNESS_NODE_PATH:-$(command -v node || true)}"
DESTINATION="$ROOT_DIR/Resources/runtime"
DEFAULT_PLUGIN_SPECS="${HARNESS_DEFAULT_PLUGIN_SPECS:-dsh1024@0.5.0 better-dsh-pet@0.3.5 dsh-mnemon@0.3.5}"

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
  echo "另一个 Runtime 打包正在运行（或存在陈旧锁目录 ${LOCK_DIR}）。确认没有并发运行后可手动删除该目录。" >&2
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

# Reject an incompatible Node before resolving the default profile. This
# avoids spending time on a package install that cannot run the supported
# plugin set afterward.
NODE_VERSION_OUTPUT="$("$STAGING_ROOT/runtime/node/bin/node" --version 2>&1)" || {
  echo "内置 Node 无法运行：$NODE_VERSION_OUTPUT" >&2
  exit 1
}
[[ "$NODE_VERSION_OUTPUT" =~ ^v[0-9]+ ]] || {
  echo "内置 Node 版本输出异常：$NODE_VERSION_OUTPUT" >&2
  exit 1
}
NODE_VERSION="${NODE_VERSION_OUTPUT#v}"
IFS=. read -r NODE_MAJOR NODE_MINOR _ <<< "$NODE_VERSION"
if (( NODE_MAJOR < 22 || (NODE_MAJOR == 22 && NODE_MINOR < 19) )); then
  echo "内置 Node 版本过低：$NODE_VERSION_OUTPUT；插件运行时至少需要 Node 22.19.0。" >&2
  exit 1
fi
echo "内置 Node 探针通过：$NODE_VERSION_OUTPUT"

# Ship a private first-run profile so a fresh App installation already contains
# the supported default plugins. This profile is copied into the user's
# App-owned DSH_HOME only when no profile exists; existing profiles and
# explicit plugin removal are never overwritten.
DEFAULT_PROFILE_HOME="$STAGING_ROOT/runtime/default-profile"
DEFAULT_RUNTIME_PATH="$STAGING_ROOT/runtime/bin:$STAGING_ROOT/runtime/node/bin:$STAGING_ROOT/runtime/node_modules/.bin:/usr/bin:/bin"
read -r -a DEFAULT_PLUGIN_SPEC_LIST <<< "$DEFAULT_PLUGIN_SPECS"
if [[ " ${DEFAULT_PLUGIN_SPEC_LIST[*]} " == *" dsh-mnemon@0.3.5 "* ]]; then
  [[ -x "$STAGING_ROOT/runtime/bin/mnemon" ]] || {
    echo "默认 profile 包含 dsh-mnemon，但 Runtime 中没有私有 Mnemon CLI；请先运行 script/fetch_mnemon_cli.sh。" >&2
    exit 2
  }
fi
mkdir -p "$DEFAULT_PROFILE_HOME"
PATH="$DEFAULT_RUNTIME_PATH" \
  DSH_HOME="$DEFAULT_PROFILE_HOME" \
  "$STAGING_ROOT/runtime/node_modules/.bin/dsh" --profile web --dump-config >/dev/null
for plugin_spec in "${DEFAULT_PLUGIN_SPEC_LIST[@]}"; do
  PATH="$DEFAULT_RUNTIME_PATH" \
    DSH_HOME="$DEFAULT_PROFILE_HOME" \
    "$STAGING_ROOT/runtime/node_modules/.bin/dsh" plugin --profile web add "$plugin_spec"
done
[[ -f "$DEFAULT_PROFILE_HOME/profiles/web/package.json" ]] || {
  echo "默认插件 profile 未生成 package.json。" >&2
  exit 1
}

# better-dsh-pet is published as a cross-platform DSH bundle. On macOS, apply
# the reviewed adapter after the official package is resolved so its Electron
# helper uses the App-owned DSH_HOME and does not rely on Windows APIs or
# globally installed runtimes.
if [[ "$(uname -s)" == "Darwin" && " ${DEFAULT_PLUGIN_SPEC_LIST[*]} " == *" better-dsh-pet@0.3.5 "* ]]; then
  PET_PACKAGE="$DEFAULT_PROFILE_HOME/profiles/web/node_modules/better-dsh-pet"
  "$ROOT_DIR/script/patch_better_dsh_pet_macos.sh" "$PET_PACKAGE"
fi
# Fixed-model Mnemon reviews inherit the parent session through the fork
# provider. Filter image blocks in that child seed while leaving normal
# conversations and follow-main-chain reviews unchanged.
HARNESS_PATCH_NODE_PATH="$STAGING_ROOT/runtime/node/bin/node" \
  "$ROOT_DIR/script/patch_dsh_mnemon_text_only_review.sh" "$STAGING_ROOT/runtime"
# Harness creates this shared directory with absolute links to the temporary
# staging Runtime. It is intentionally regenerated on the user's first start,
# where the links can point at the final bundled Runtime path; shipping the
# staging links would leave a broken profile and make bundle signing fail.
if [[ -d "$DEFAULT_PROFILE_HOME/profiles/node_modules" ]]; then
  rm -rf "$DEFAULT_PROFILE_HOME/profiles/node_modules"
fi
echo "默认插件 profile 已生成：$DEFAULT_PLUGIN_SPECS"

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
