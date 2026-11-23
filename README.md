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
  every call), and netcat compatibility (`netcat`/`telnet` → `nc`). An alias is not defined when your shell already has an alias or function of that name; yours is kept, and `wb status` lists what was left alone.
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
- **SonarQube token in your keyring** (needs `secret-tool`; on macOS the
  [Keychain-backed one](#secret-tool-on-macos) is used): `sonar-token-set`
  asks for a token with the input hidden and stores it, `sonar-token-get`
  prints it for capturing (`SONAR_TOKEN="$(sonar-token-get)" some-command`),
  and `sonar-token-clear` removes it. `sq` reads the same entry
  (`service sonarqube`, `account scanner`).
- **`secret-tool` on macOS**: a `secret-tool` that stores secrets in the login
  Keychain, with libsecret's syntax, so scripts written for Linux work
  unchanged. Defined only on macOS.
- Installers for `cosign`, `trivy`, `bitwarden`, `bw-cli`, `1password`,
  `op-cli`, `sonar-scanner`, `sonar` (the SonarQube CLI) and `secret-tool` —
  run `wb tools install <name>` (or `wb tools upgrade <name>`).

## What each installer verifies

| Installer | Linux | macOS |
|---|---|---|
| `cosign` | Release binary checked against the SHA-256 GitHub publishes for it (cosign's checksums file as a fallback). | Homebrew |
| `trivy` | Aqua's rpm or deb repository, with the repository key pinned (`825AD9036F7C850E6A6FED4935B8ACA44FD9CA9F`); the rpm repository is limited to the `trivy` package. | Homebrew |
| `bitwarden` | `.deb`/`.rpm`/AppImage checked against the SHA-256 GitHub publishes; Flathub where Flatpak is the route. On Arch, the AppImage, or the AUR `bitwarden-bin` package with `yay` only when `WORKBENCH_ALLOW_AUR=true`. | Homebrew cask |
| `bw-cli` | npm (`@bitwarden/cli`), or the release zip checked against the SHA-256 GitHub publishes. | Homebrew |
| `1password` | 1Password's rpm/deb/zypper repository with its key pinned (`3FEF9748469ADBE15DA7CA80AC2D62742012EA22`), plus the pinned debsig keyring on Debian; Flathub on other distros. On Arch, only with `WORKBENCH_ALLOW_AUR=true`: the AUR `1password` package (`yay`, or `makepkg`), verified by makepkg's own `validpgpkeys` check of 1Password's signature, so the 1Password key must be in your keyring. Without the opt-in it prints the command to run and fails. | Homebrew cask |
| `op-cli` | The same pinned 1Password repositories; on other distros, the CLI zip, installed only if its `op.sig` verifies (`gpgv`) against the pinned 1Password key. | Homebrew cask |

`sonar-scanner`, `sonar` and `secret-tool` are covered in
[SonarQube tools](#sonarqube-tools) below.

### AUR packages (Arch)

AUR packages are build scripts nobody at workbench has reviewed, run as you
and then installed as root, so installers use them only when you opt in
(workbench-core D100). In `~/.config/workbench/local/settings.sh`:

```sh
WORKBENCH_ALLOW_AUR=true
```

## SonarQube tools

| Installer | What it does |
|---|---|
| `sonar-scanner` | Linux: the SonarScanner CLI zip with its own JRE (no Java needed), unpacked to `~/.local/share/sonar-scanner/` and linked from `~/.local/bin`. The latest version is looked up in Maven Central's metadata, and the zip is checked against the `.sha256` Sonar publishes beside it. That is an integrity check only: the checksum and the zip come from the same host, and the `.asc` signature is not checked. macOS: Homebrew. |
| `sonar` | The SonarQube CLI (currently beta). SonarSource's own `install.sh`, downloaded to a file and run, never piped into a shell. **That script doesn't verify the binary it downloads.** workbench runs it with `PROFILE=/dev/null` so it doesn't edit your shell rc file, and links the binary into `~/.local/bin`. Apple silicon and Linux only. |
| `secret-tool` | The libsecret command-line tool (`libsecret` or `libsecret-tools`, by distro). Linux only: on macOS the module defines a Keychain-backed `secret-tool` itself ([below](#secret-tool-on-macos)). |

After `wb tools install sonar-scanner`, the installer installs `secret-tool`
if it is missing and, when there is a terminal and no token stored yet, asks
whether to store one. Answering no is fine: run `sonar-token-set` any time.
An existing token is never replaced by the installer.

Neither the installer nor the helpers set the server address. Give the
scanner `SONAR_HOST_URL` (for example in `~/.config/workbench/local/settings.sh`)
or `sonar.host.url` in a project's `sonar-project.properties`.

`~/.local/bin/sonar-scanner` and `~/.local/bin/sonar` are replaced only when
they are already links workbench made. A file or link of your own is left
alone and the installer stops with a message.

| Variable | Installer | Effect |
|---|---|---|
| `SONAR_SCANNER_VERSION` | `sonar-scanner` | Install that release instead of the latest, e.g. `SONAR_SCANNER_VERSION=8.4.0.16527 wb tools install sonar-scanner`. Sonar's download host answers a version that doesn't exist with HTTP 403, so a 403 usually means a mistyped version. |

## `secret-tool` on macOS

On macOS, `shell/macos.sh` defines a `secret-tool` shell function that keeps
secrets in your login Keychain. It takes libsecret's arguments, so
`sonar-token-set`, `sonar-token-get`, `sq` and any script you wrote for Linux
use it unchanged. Nothing is installed; it loads with the module in a new
shell, and only on macOS.

```sh
printf '%s' "$value" | secret-tool store --label="Example" service example account me
secret-tool lookup service example account me     # prints the secret, no trailing newline
secret-tool clear service example account me
```

`store` reads the secret from standard input, or asks for it with the input
hidden when standard input is a terminal. `lookup` prints nothing and exits 1
when there is no such item. Items show up in Keychain Access under the
`--label` you gave, or the service name.

- **The secret never appears in a command's arguments.** `store` passes it to
  `security -i` on standard input, so it isn't visible in `ps`.
- **Only `service` and `account` are accepted, and both are required.** A
  Keychain item has fixed fields, not libsecret's free-form attributes. Any
  other attribute is refused with a message.
- **Values can't contain a double quote, a backslash or a newline.**
- **`search` and `--collection` are not supported.**
- **`store` reads the item back** and fails if the Keychain doesn't hold what
  you gave it.
- **Keychain prompts.** The first read from a different program, such as a
  terminal other than the one that stored the item, may ask you to allow it.

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
