# Changelog

All notable changes to `workbench-security` are documented here.

## [Unreleased]

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
