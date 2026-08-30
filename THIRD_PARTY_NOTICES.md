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

## better-dsh-pet

The fresh-install Runtime profile includes the upstream `better-dsh-pet@0.3.5`
DSH bundle. The macOS-specific helper adapter is kept under
`Resources/better-dsh-pet-macos` and is based on the public macOS reference
port. The upstream code is MIT-licensed; the animation assets may carry
additional non-commercial and attribution requirements, so releases preserve
the upstream package README and license.

- Upstream repository: <https://github.com/ysppwn721/better-dsh-pet>
- macOS reference port: <https://github.com/williamhadeslee/better-dsh-pet-macos>

## dsh-mnemon and Mnemon Native

The fresh-install Runtime profile includes `dsh-mnemon@0.3.5`, installed
through the standard Harness plugin registry. The Runtime Bundle also carries
the architecture-specific `mnemon` Native CLI `0.2.5`; the release workflow
downloads the official archive and verifies its upstream SHA-256 checksum
before placing it under the App Runtime. The launcher does not install this
binary globally.

- dsh-mnemon repository: <https://github.com/omdsh-dev/dsh-mnemon>
- dsh-mnemon license: MIT
- Mnemon Native repository: <https://github.com/mnemon-dev/mnemon>
- Mnemon Native release: <https://github.com/mnemon-dev/mnemon/releases/tag/v0.2.5>
- Mnemon Native license: MIT

## Other dependencies

Node.js, Swift, SwiftUI, AppKit, WebKit, pnpm, and transitive npm packages are
used by the build or Runtime Bundle. The release workflow pins pnpm
(10.19.0) inside the App Runtime; it is not installed globally. Their respective licenses remain with
their authors. A release artifact built with the workflow includes the
Runtime dependency tree; inspect the corresponding upstream package metadata
before redistributing a modified artifact.

The controlled private-toolchain recovery list currently includes jq 1.7.1:

- Repository: <https://github.com/jqlang/jq>
- License: MIT
- The Launcher downloads only the architecture-specific release asset whose
  URL, size, SHA-256, source, and license are pinned in the application code.

## Trademarks and service terms

DeepSeek, Harness, Codex, ChatGPT, and OpenAI are names and marks of their
respective owners. This project is an independent, unofficial launcher. It is
not endorsed by DeepSeek, OpenAI, or the authors of the referenced plugins.
