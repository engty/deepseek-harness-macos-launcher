#!/usr/bin/env bash
set -euo pipefail

RUNTIME_ROOT="${1:-}"
if [[ -z "$RUNTIME_ROOT" || ! -d "$RUNTIME_ROOT" ]]; then
  echo "usage: $0 /path/to/runtime" >&2
  exit 2
fi

NODE_BIN="${HARNESS_PATCH_NODE_PATH:-$RUNTIME_ROOT/node/bin/node}"
if [[ ! -x "$NODE_BIN" ]]; then
  echo "没有找到可执行 Node，无法应用 dsh-mnemon 文本复盘兼容补丁。" >&2
  exit 2
fi

exec "$NODE_BIN" - "$RUNTIME_ROOT" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const runtimeRoot = process.argv[2];
const mnemonSourcePath = path.join(
  runtimeRoot,
  "default-profile",
  "profiles",
  "web",
  "node_modules",
  "dsh-mnemon",
  "lib",
  "index.js"
);
const forkSourcePath = path.join(
  runtimeRoot,
  "node_modules",
  "@deepseek-ai",
  "dsh-subagent-fork-in-process",
  "lib",
  "index.js"
);

function patchFile(filePath, transform) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`缺少需要补丁的 Runtime 文件：${filePath}`);
  }
  const source = fs.readFileSync(filePath, "utf8");
  const result = transform(source);
  if (result === null) {
    throw new Error(`Runtime 文件未匹配兼容补丁锚点：${filePath}`);
  }
  if (result !== source) {
    fs.writeFileSync(filePath, result, "utf8");
    console.log(`已应用 dsh-mnemon 文本复盘兼容补丁：${filePath}`);
  }
}

function patchMnemon(source) {
  if (source.includes("dshMnemonTextOnly: true")) return source;
  const original = [
    "\t\t\tconst resolvedAgentOptions = fixed === void 0 ? baseAgentOptions : {",
    "\t\t\t\t...baseAgentOptions ?? {},",
    "\t\t\t\tprovider: fixed.provider,",
    "\t\t\t\tmodel: fixed.model",
    "\t\t\t};"
  ].join("\n");
  const replacement = [
    "\t\t\tconst resolvedAgentOptions = fixed === void 0 ? baseAgentOptions : {",
    "\t\t\t\t...baseAgentOptions ?? {},",
    "\t\t\t\t...operation === \"review\" ? { dshMnemonTextOnly: true } : {},",
    "\t\t\t\tprovider: fixed.provider,",
    "\t\t\t\tmodel: fixed.model",
    "\t\t\t};"
  ].join("\n");
  if (source.split(original).length - 1 !== 1) return null;
  return source.replace(original, replacement);
}

function patchFork(source) {
  if (source.includes("mnemonForkSeed(request)")) return source;
  const classAnchor = "var ForkInProcessProvider = class {";
  const seedAnchor = "const seed = completedTurnPrefix(request.parent);";
  if (!source.includes(classAnchor) || source.split(seedAnchor).length - 1 !== 2) return null;
  const helpers = [
    "function sanitizeMnemonForkValue(value) {",
    "\tif (Array.isArray(value)) return value.map((item) => sanitizeMnemonForkValue(item));",
    "\tif (value && typeof value === \"object\") {",
    "\t\tif (!Array.isArray(value) && value.type === \"image\") {",
    "\t\t\treturn { type: \"text\", text: \"[image content omitted from text-only Mnemon review]\" };",
    "\t\t}",
    "\t\treturn Object.fromEntries(Object.entries(value).map(([key, item]) => [key, sanitizeMnemonForkValue(item)]));",
    "\t}",
    "\treturn value;",
    "}",
    "function sanitizeMnemonForkSeed(seed) {",
    "\treturn seed.map((event) => sanitizeMnemonForkValue(event));",
    "}",
    "function mnemonForkSeed(request) {",
    "\tconst seed = completedTurnPrefix(request.parent);",
    "\treturn request.agentOptions?.dshMnemonTextOnly === true ? sanitizeMnemonForkSeed(seed) : seed;",
    "}"
  ].join("\n");
  const replacedSeeds = source.replaceAll(seedAnchor, "const seed = mnemonForkSeed(request);");
  return replacedSeeds.replace(classAnchor, `${helpers}\n${classAnchor}`);
}

const hasMnemon = fs.existsSync(mnemonSourcePath);
const hasFork = fs.existsSync(forkSourcePath);
if (hasMnemon) {
  patchFile(mnemonSourcePath, patchMnemon);
  // Some official Runtime package graphs expose the fork provider only from
  // a nested dependency path, or omit it entirely. The launcher already
  // treats that provider as optional, so a missing top-level file must not
  // make an otherwise valid Runtime fail packaging.
  if (hasFork) {
    patchFile(forkSourcePath, patchFork);
  } else {
    console.log("Runtime 未暴露 dsh-subagent-fork-in-process，跳过 Mnemon 图片过滤补丁。");
  }
} else if (hasFork) {
  // Keep the bundled fork ready for a later user-installed dsh-mnemon plugin.
  patchFile(forkSourcePath, patchFork);
} else {
  console.log("默认 Runtime 未包含 dsh-mnemon 或 fork provider，跳过文本复盘补丁。");
}
NODE
