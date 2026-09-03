#!/usr/bin/env bash
set -euo pipefail

# Download the pinned Mnemon Native CLI into a Runtime-owned directory. The
# archive is verified against the upstream checksums file before extraction;
# no global package manager or shell configuration is touched.
DESTINATION_ROOT="${1:-}"
VERSION="${HARNESS_MNEMON_VERSION:-0.2.7}"
ARCHITECTURE="${HARNESS_MNEMON_ARCH:-$(uname -m)}"

if [[ -z "$DESTINATION_ROOT" ]]; then
  echo "usage: HARNESS_MNEMON_VERSION=0.2.7 $0 /path/to/runtime/bin" >&2
  exit 2
fi

case "$ARCHITECTURE" in
  arm64|aarch64) RELEASE_ARCH="arm64" ;;
  x86_64|amd64) RELEASE_ARCH="amd64" ;;
  *)
    echo "不支持的 Mnemon 架构：$ARCHITECTURE" >&2
    exit 2
    ;;
esac

ASSET="mnemon_${VERSION}_darwin_${RELEASE_ARCH}.tar.gz"
BASE_URL="https://github.com/mnemon-dev/mnemon/releases/download/v${VERSION}"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-mnemon.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

mkdir -p "$DESTINATION_ROOT"
curl -LfsS --retry 3 "$BASE_URL/$ASSET" -o "$WORK_ROOT/$ASSET"
curl -LfsS --retry 3 "$BASE_URL/checksums.txt" -o "$WORK_ROOT/checksums.txt"

EXPECTED_SHA="$(awk -v asset="$ASSET" '
  { name = $2; sub(/^\*/, "", name); if (name == asset) { print $1; exit } }
' "$WORK_ROOT/checksums.txt")"
ACTUAL_SHA="$(shasum -a 256 "$WORK_ROOT/$ASSET" | awk '{print $1}')"
EXPECTED_SHA_NORMALIZED="$(printf '%s' "$EXPECTED_SHA" | tr '[:upper:]' '[:lower:]')"
ACTUAL_SHA_NORMALIZED="$(printf '%s' "$ACTUAL_SHA" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA_NORMALIZED" != "$ACTUAL_SHA_NORMALIZED" ]]; then
  echo "Mnemon 下载校验失败：$ASSET" >&2
  exit 1
fi

mkdir -p "$WORK_ROOT/extract"
tar -xzf "$WORK_ROOT/$ASSET" -C "$WORK_ROOT/extract"
MNEMON_BINARY="$(find "$WORK_ROOT/extract" -type f -name mnemon -perm -111 -print -quit)"
if [[ -z "$MNEMON_BINARY" ]]; then
  echo "Mnemon 压缩包中没有可执行文件。" >&2
  exit 1
fi

VERSION_OUTPUT="$("$MNEMON_BINARY" --version 2>&1)"
if [[ "$VERSION_OUTPUT" != "mnemon version $VERSION"* ]]; then
  echo "Mnemon 版本探针失败：$VERSION_OUTPUT" >&2
  exit 1
fi

install -m 755 "$MNEMON_BINARY" "$DESTINATION_ROOT/mnemon"
echo "Mnemon Native 已写入：$DESTINATION_ROOT/mnemon ($VERSION_OUTPUT)"
