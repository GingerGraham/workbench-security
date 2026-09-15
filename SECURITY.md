# Security policy

## Supported versions

Only the latest tagged release (the latest `vX.Y.Z` tag) is supported.
There are no maintained LTS branches.

## Reporting a vulnerability

**Please don't open a public issue for a security problem.** Use
GitHub's private vulnerability reporting instead: go to the
[Security tab](https://github.com/GingerGraham/workbench-security/security)
→ "Report a vulnerability". This opens a private advisory only visible
to the maintainer until it's resolved.

This is a solo-maintained project — response is best-effort, not
covered by an SLA, but security reports get triaged ahead of everything
else in the backlog.

## Trust boundaries worth knowing about

This module ships shell content (aliases, functions) and, where
declared, an `install-<tool>` function — but it's
`workbench-core`'s sync engine that actually fetches, places, and
sources any of it. The engine-level trust boundaries (tarball-only
production fetch, SSH deploy keys for private/`branch:`-tracked
modules, engine-computed destinations, `..`/absolute-path rejection)
live in `workbench-core`'s own
[`SECURITY.md`](https://github.com/GingerGraham/workbench-core/blob/main/SECURITY.md)
— report anything that breaks those there.

What's specific to this repo:

- **This module's registered shell content is confined to its own
  snapshot namespace** — it cannot declare a `dest` and land content
  anywhere else. If you find a manifest shape that escapes that, report
  it.

## Automated PR checks

Every pull request to this repo runs three automated checks before
merge, shipped from `workbench-core` so every module stays on the same
list:

- **Secrets** (gitleaks) — hardcoded credentials, tokens, keys.
- **Malware signatures** (clamav) — known-malicious content via ClamAV's
  signature database.
- **Dangerous shell patterns** — a maintained list of known-bad
  constructs (remote-pipe-to-shell, world-writable permissions, etc).

These run alongside shellcheck and this repo's own structural tests.

## Out of scope

This pipeline only runs against code in `workbench-core` and the eleven
canonical `workbench-*` module repos. It says nothing about modules
obtained from anywhere else — `workbench` has no community module
submission or validation pipeline (deliberately, for now).
