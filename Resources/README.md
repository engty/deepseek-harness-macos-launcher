# Runtime Bundle

The release pipeline places a verified DeepSeek Harness runtime here when it
builds a distributable app:

```text
Resources/runtime/
  bin/dsh
  node/
  dsh/
  node_modules/
```

`AppIcon.png` is the source artwork for the macOS application icon. The build
script converts it to the multi-resolution `AppIcon.icns` placed in the app
bundle.

The local development workspace may also contain an ignored `runtime/`
fixture with the currently verified Node and Harness dependency tree. Release
builds must replace it with the controlled-channel Runtime Bundle rather than
committing `node_modules` to the source repository.

Development builds may point the launcher at an existing runtime with:

```sh
HARNESS_DSH_PATH=/absolute/path/to/dsh ./script/build_and_run.sh
```

The launcher never runs `git pull` or builds the Harness source tree on a user
machine. The release pipeline is responsible for producing the Runtime Bundle
and its SHA-256 manifest described in `prd.md`.

Release checks use the repository-level `compatibility-matrix.json` and
`script/validate_release.sh`. Developer ID and notarization are intentionally
outside this product's scope.

The packaged `bin/deepseek-harness-plugin` helper forwards standard
`plugin --profile web ...` commands for advanced automation. The App UI uses a
transactional staging slot; direct helper use is intentionally an advanced
operation and follows the official Harness CLI semantics.
