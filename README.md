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
    every boot (`systemd-cryptenroll --tpm2-with-pin=yes`). `rotate-luks-key`'s
    post-rotation TPM2 offer stays TPM2-only; re-run
    `enroll-luks-tpm2 --with-pin` afterwards if you want a PIN.
- `install-cosign`, `install-trivy`, `install-bitwarden`, `install-bw-cli`,
  `install-1password`, `install-op-cli` — via `wb tools update`.

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
