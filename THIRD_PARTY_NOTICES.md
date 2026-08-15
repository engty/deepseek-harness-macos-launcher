# Third-party notices

## DeepSeek Harness

The launcher is designed to run the open-source DeepSeek Harness runtime
(`@deepseek-ai/dsh`) and its official `dsh --profile web` interface:

- Repository: <https://github.com/deepseek-ai/deepseek-harness>
- License shown by the upstream repository: MIT
- Runtime package: <https://www.npmjs.com/package/@deepseek-ai/dsh>

The source repository does not vendor the Runtime Bundle or its `node_modules`.
Release builds assemble a pinned Runtime Bundle in GitHub Actions. The
upstream repository and the generated dependency tree remain the authoritative
sources for their notices and licenses.

## dsh-llm-codex

The launcher does not copy or embed the `dsh-llm-codex` source. It only supports
installing it through the standard Harness plugin command:

- Repository: <https://github.com/yequ172672/dsh-codex-subscription>
- Package: <https://www.npmjs.com/package/dsh-llm-codex>

Its license, terms, provider protocol, and ChatGPT subscription behavior are
controlled by that upstream project and must be reviewed there before
redistribution. Installing it is an explicit user action.

## Other dependencies

Node.js, Swift, SwiftUI, AppKit, WebKit, pnpm, and transitive npm packages are
used by the build or Runtime Bundle. Their respective licenses remain with
their authors. A release artifact built with the workflow includes the
Runtime dependency tree; inspect the corresponding upstream package metadata
before redistributing a modified artifact.

## Trademarks and service terms

DeepSeek, Harness, Codex, ChatGPT, and OpenAI are names and marks of their
respective owners. This project is an independent, unofficial launcher. It is
not endorsed by DeepSeek, OpenAI, or the authors of the referenced plugins.
