# Runtime Bundle

The release pipeline places a verified DeepSeek Harness runtime here when it
builds a distributable app:

```text
Resources/runtime/
  bin/dsh
  node/
  dsh/
  node_modules/
    .bin/pnpm
  bin/
    mnemon              # pinned Mnemon Native CLI for dsh-mnemon
  default-profile/
    profiles/web/       # fresh-install profile: 1024 Store + pet + Mnemon + GenUI + privacy router
```

`AppIcon.png` is the source artwork for the macOS application icon. The build
script converts it to the multi-resolution `AppIcon.icns` placed in the app
bundle.

The local development workspace may also contain an ignored `runtime/`
fixture with the currently verified Node and Harness dependency tree. Release
builds must replace it with the controlled-channel Runtime Bundle rather than
committing `node_modules` to the source repository. The release bundle must
include a pinned `pnpm` package under `node_modules/.bin/pnpm`; the Launcher
gives that private directory to Harness child processes without changing the
user's shell PATH.

Development builds may point the launcher at an existing runtime with:

```sh
HARNESS_DSH_PATH=/absolute/path/to/dsh ./script/build_and_run.sh
```

The launcher never runs `git pull` or builds the Harness source tree on a user
machine. The release pipeline is responsible for producing the Runtime Bundle
and its SHA-256 manifest described in `prd.md`.

The Runtime Bundle also contains a pinned default web profile with `dsh1024`
(`0.5.0`), `better-dsh-pet` (`0.3.5`), `dsh-mnemon` (`0.4.6`),
`@changfenhuang/dsh-genui` (`0.9.8`) and the reviewed
`dsh-privacy-router` (commit `1b51e6d`). Current DeepSeek models provide native
multimodal input, so the launcher no longer bundles an external vision plugin.
GenUI teaches the model the `dsh-ui` fence and renders safe interactive cards,
charts and forms inside replies.
The privacy router is installed but disabled in a fresh profile because it
requires a configured local Provider before it can protect the main route. Once
that Provider is ready, enable it from `插件 → 已安装插件`.
The bundle carries a checksum-verified, architecture-matched Mnemon Native
CLI (`0.2.5`) under `runtime/bin`; it is visible only to Harness child
processes and is not installed into the user's global PATH. The pet is disabled by default and
can be enabled from `插件 → 桌宠 → 显示桌宠`. Its bubble size supports 40%–120%
(default 100%). On first launch, the Launcher
copies that profile into the App-owned `$DSH_HOME` only when no user profile
exists. Existing profiles are left untouched, so removing a default plugin is
not undone on restart.

On macOS, the build applies the reviewed adapter in
`Resources/better-dsh-pet-macos` to the upstream npm package. The desktop
helper downloads the pinned Electron archive only when the user first shows
the pet, stores it under the App-owned DSH_HOME, and verifies its SHA-256. Its
optional voice output uses macOS `/usr/bin/say` and does not upload audio. The
upstream microphone recognition depends on Windows SAPI or a separately
downloaded SenseVoice model, so that input path remains unavailable in this
macOS adapter. It does not use a global Electron or alter the user's shell
PATH.

Dependencies that are not shipped in the Runtime are never installed globally.
The controlled recovery list is stored under the App's private Application
Support toolchain directory, with one immutable version directory and a
manifest per tool. Unknown commands or dependencies are reported to the user
instead of being executed.

Release checks use the repository-level `compatibility-matrix.json` and
`script/validate_release.sh`. Developer ID and notarization are intentionally
outside this product's scope.

The packaged `bin/deepseek-harness-plugin` helper forwards standard
`plugin --profile web ...` commands for advanced automation. The App UI uses a
transactional staging slot; direct helper use is intentionally an advanced
operation and follows the official Harness CLI semantics.

## Credential storage

The launcher stores the user's DeepSeek API key locally in macOS Keychain and
also in Harness's required `$DSH_HOME/.credentials.yaml` file (mode `0600`).
The two local copies let the native balance query and the official Harness
Models provider use the same credential. The project has no credential server,
telemetry, or remote synchronization service. Keys are not committed to the
repository and are redacted from operation logs and diagnostic exports.

The macOS App update menu checks the outer launcher release on GitHub. Runtime
checks query every valid SemVer published for the official
`@deepseek-ai/dsh` npm package, including `rc` and `beta` builds, so a newly
published Harness release is not missed when the controlled artifact feed is
temporarily unavailable. The version-adjacent download button rebuilds a full
Runtime in the App-owned cache with the bundled pnpm, then verifies the exact
version, archive size/hash, and launch preflight before activation. It never
overwrites the Runtime with a bare npm tarball, never writes to global
Node/pnpm, and never changes the user's plugin profile. When a controlled
HTTPS manifest is available, that hash-verified artifact remains the preferred
update channel.
