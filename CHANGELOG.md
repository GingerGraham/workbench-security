# Changelog

All notable changes to `workbench-security` are documented here.

## [Unreleased]

### Security

- **1Password's zypper repo key refresh is now scoped to that one repo,
  not every configured repo on the host.** `zypper --gpg-auto-import-keys
  refresh` with no repo argument auto-accepts new signing keys for every
  repo configured on the system, not only the one just added (security
  review M4). Both `_1password-install-suse` and `_op-install-suse` now
  pass the `1password` repo alias explicitly.

## [0.3.0] - 2026-09-23

### Added

- **Manual `workflow_dispatch` release override.** `release.yml` now
  accepts a `bump_type` (patch/minor/major) input to force a release
  through `workbench-core`'s reusable `module-release.yml`, regardless of
  what Conventional Commits since the last tag would compute — a floor,
  never a downgrade of a higher severity already pending. Manual dispatch
  only runs from `main`. See `workbench-core`'s `docs/decisions-log.md` D67.

## [0.2.2] - 2026-09-16

### Fixed

- `enroll-luks-tpm2` and `rotate-luks-key` no longer show up in
  `wb functions`/module-getter listings on a host missing one of their
  required tools (`cryptsetup`, `blkid`, `systemd-cryptenroll`,
  `systemctl`, `python3`). Both now declare an availability predicate
  via `workbench-core`'s `_wb_alias_availability`, backed by a new
  quiet `_tpm_tools_present` twin of the existing `_tpm_require_tools`
  preflight check — no behavior change to either function's runtime
  preflight, which still logs which specific tool is missing.

## [0.2.1] - 2026-09-15

### Added

- **Agent-instruction files** (`AGENTS.md`, `CLAUDE.md`,
  `.github/copilot-instructions.md`,
  `.claude/skills/conventional-commits/SKILL.md`) — ports
  `workbench-core`'s D32 agent-instruction topology to this repo. See
  `workbench-core`'s `docs/decisions-log.md` D58.
- **Repo governance files** (`.github/PULL_REQUEST_TEMPLATE.md`,
  `.github/ISSUE_TEMPLATE/{bug_report,feature_request,config}.yml`,
  `.github/CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`) — ports
  `workbench-core`'s D31 governance-file topology to this repo,
  piloted on `workbench-git` first. See `workbench-core`'s
  `docs/decisions-log.md` D60.

### Fixed

- Suppressed a `gitleaks` false positive on `install-1password`'s
  documentation comment: the entropy-based `generic-api-key` rule flagged
  1Password's own published GPG signing-key fingerprint as a possible
  secret. It's meant to be public — that's how fingerprint verification
  works — so marked with an inline `gitleaks:allow` rather than treated
  as a real credential.

## [0.2.0] - 2026-09-09

### Added

- Added `installed-cosign`, `installed-trivy`, `installed-bw-cli`,
  `installed-1password`, `installed-op-cli` — reports install status to
  `wb tools upgrade`/`wb tools list --status` (workbench-core §12 D43).
  `installed-1password` also checks the flatpak-fallback install path.
  `install-bitwarden` deliberately has no predicate — see
  shell/installers.sh comment for why.

## [0.1.0] - 2026-09-09

### Added

- Initial decomposition from `workbench-precursor` (Wave C): ClamAV/netcat
  aliases, `sq`, LUKS2+TPM2 enrollment and passphrase rotation
  (`enroll-luks-tpm2`/`rotate-luks-key`) with its Python PTY-capture
  worker, and `install-cosign`/`install-trivy`/`install-bitwarden`/
  `install-bw-cli`/`install-1password`/`install-op-cli`.

### Fixed

- `sq` was an alias with `secret-tool lookup ...` baked in via command
  substitution at *definition* time — the token was captured once, when
  the file was sourced, and never refreshed for the rest of the shell
  session even if the secret rotated. Converted to a function that
  re-reads the token on every invocation.
- `_op-install-binary` used `grep -oP` (GNU-only PCRE lookbehind) to parse
  the latest 1Password CLI version, which errors on BSD grep. Replaced
  with a portable `sed` capture group (same class of issue Copilot review
  caught in `workbench-gpg`'s `_gpg_bw_logged_in`).

### Changed

- The Python PTY-capture worker is read directly from this module's own
  fetched snapshot (`workers/disk-encryption-pty-capture.py`, resolved via
  `BASH_SOURCE`) rather than deployed anywhere — `~/.ssh/`-style denylist
  concerns don't apply here, but there's no reason to deploy a file only
  one script in the same repo ever calls.
- `WORKBENCH_OS`/`WORKBENCH_DISTRO`/`WORKBENCH_ARCH` replace
  `DOTFILES_OS`/`DOTFILES_DISTRO` throughout.
- `90-local.sh` PATH-warning references now point at
  `~/.config/workbench/local/settings.sh` (D22 in `workbench-core`).
