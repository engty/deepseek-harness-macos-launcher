# Security policy

## Scope

This repository contains a macOS launcher for DeepSeek Harness. It does not
contain user profiles, API keys, Codex credentials, Keychain exports, or a
bundled development `Resources/runtime/` directory.

Never paste API keys, OAuth tokens, `auth.json`, Keychain exports, or private
runtime data into an issue, pull request, log, diagnostic archive, or commit.

## Reporting

Please do not disclose an unpatched vulnerability in a public issue. Use a
private GitHub security advisory for this repository when available, or contact
the maintainers privately through the repository owner before publishing
details. Include a minimal reproduction, affected commit or release, impact,
and a suggested mitigation. Do not include live credentials in the report.

## Release security boundary

The Runtime feed uses HTTPS, artifact size checks, and SHA-256 checks. Local
release signing supports an optional Developer ID Application identity with
Hardened Runtime; the signing private key is never stored in this repository.
GitHub-hosted builds remain ad-hoc unless a separately controlled signing job
imports a short-lived certificate into a temporary keychain. Verify published
checksums before redistribution.
