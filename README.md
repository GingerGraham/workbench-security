# workbench-security

Security scanners, signing tooling, password manager CLIs/apps, and
LUKS2+TPM2 disk-encryption management for the
[`workbench`](https://github.com/GingerGraham/workbench-core) ecosystem.

An **ecosystem module** (`workbench-core` ARCHITECTURE.md §2) — meaningless
standalone. Requires `workbench-core` installed first:

```sh
wb add security
```

## What this gives you

- ClamAV aliases (`av`/`clam`/`scan`/`clam-home`/`clam-update`, ...),
  `sq` (sonar-scanner with a token freshly re-read from `secret-tool` on
  every call), and netcat compatibility (`netcat`/`telnet` → `nc`).
- **LUKS2 + TPM2 disk encryption** (Linux only): `enroll-luks-tpm2`,
  `rotate-luks-key`. Never wipes a recovery or password slot — only ever
  targets the `tpm2` slot type, and always guarantees a recovery key
  exists before touching TPM2. Optionally offers to store a newly
  generated recovery key in Bitwarden or 1Password as a secure note.
  - **Threat model.** `enroll-luks-tpm2` on its own enrolls TPM2-only
    unlock (PCRs 0+2+5+7): the disk unlocks automatically whenever this
    machine boots its unmodified boot chain. That protects against a disk
    removed from the machine, not against the whole machine being stolen —
    a stolen, powered-off laptop boots to an unlocked root filesystem and
    only the login screen protects the data. Running-system attacks
    (DMA-capable ports, TPM bus sniffing on discrete TPMs, login/lock-screen
    flaws) also remain.
  - **`--with-pin`.** `enroll-luks-tpm2 --with-pin` also requires a PIN at
    every boot (`systemd-cryptenroll --tpm2-with-pin=yes`).
    `rotate-luks-key --with-pin` does the same for the TPM2 enrollment it
    offers after a rotation; without it, that enrollment is TPM2-only.
  - **A PIN is never dropped silently.** Without `--with-pin`, when a
    device already has a TPM2+PIN enrollment, both commands ask "This
    replaces your TPM2+PIN unlock with TPM2-only. Continue? [y/N]" before
    changing anything, and refuse when there is no terminal to ask at.
  - **Ctrl-C.** Interrupting while the recovery key is held in a temporary
    file (the PTY transcript, or the 1Password item file) removes that file
    and stops the command.
- Installers for `cosign`, `trivy`, `bitwarden`, `bw-cli`, `1password` and
  `op-cli` — run `wb tools install <name>` (or `wb tools upgrade <name>`).

## What each installer verifies

| Installer | Linux | macOS |
|---|---|---|
| `cosign` | Release binary checked against the SHA-256 GitHub publishes for it (cosign's checksums file as a fallback). | Homebrew |
| `trivy` | Aqua's rpm or deb repository, with the repository key pinned (`825AD9036F7C850E6A6FED4935B8ACA44FD9CA9F`); the rpm repository is limited to the `trivy` package. | Homebrew |
| `bitwarden` | `.deb`/`.rpm`/AppImage checked against the SHA-256 GitHub publishes; Flathub where Flatpak is the route. On Arch, the AppImage, or the AUR `bitwarden-bin` package with `yay` only when `WORKBENCH_ALLOW_AUR=true`. | Homebrew cask |
| `bw-cli` | npm (`@bitwarden/cli`), or the release zip checked against the SHA-256 GitHub publishes. | Homebrew |
| `1password` | 1Password's rpm/deb/zypper repository with its key pinned (`3FEF9748469ADBE15DA7CA80AC2D62742012EA22`), plus the pinned debsig keyring on Debian; Flathub on other distros. On Arch, only with `WORKBENCH_ALLOW_AUR=true`: the AUR `1password` package (`yay`, or `makepkg`), verified by makepkg's own `validpgpkeys` check of 1Password's signature, so the 1Password key must be in your keyring. Without the opt-in it prints the command to run and fails. | Homebrew cask |
| `op-cli` | The same pinned 1Password repositories; on other distros, the CLI zip, installed only if its `op.sig` verifies (`gpgv`) against the pinned 1Password key. | Homebrew cask |

### AUR packages (Arch)

AUR packages are build scripts nobody at workbench has reviewed, run as you
and then installed as root, so installers use them only when you opt in
(workbench-core D100). In `~/.config/workbench/local/settings.sh`:

```sh
WORKBENCH_ALLOW_AUR=true
```

## Disk encryption internals

`enroll-luks-tpm2`/`rotate-luks-key` generate recovery keys by running
`systemd-cryptenroll --recovery-key` inside a real PTY
(`workers/disk-encryption-pty-capture.py`, Python's stdlib `pty` module —
`script(1)` isn't assumed present, since Fedora splits it out of the
default `util-linux-core` install) so password-prompt echo suppression behaves
exactly as if run directly, while transcribing the output to a root-owned,
`O_EXCL`-created file that only root ever touches. See the comments in
`shell/disk-encryption.sh` and the worker script for the full design
rationale (why `sudo` wraps the Python process rather than the inner
command, why the transcript file is named but not pre-created, etc.).

## Soft dependency on workbench-gpg

`install-bw-cli`'s installed CLI is used by `workbench-gpg`'s
`gpg-export-bitwarden`/`gpg-import-bitwarden` — no hard dependency either
direction, just a documented pairing.

## Requires

- `python3` (stdlib `pty`/`os` only) for disk-encryption recovery-key
  capture — already a hard `workbench-core` prerequisite.
- `cryptsetup`, `blkid`, `systemd-cryptenroll`, `systemctl` for disk
  encryption specifically (Linux only; `shell/disk-encryption.sh`
  self-guards on `WORKBENCH_OS == Linux`).
