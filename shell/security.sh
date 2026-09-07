#!/usr/bin/env bash
# shell/security.sh — workbench-security
# Security tool configuration — ClamAV, sonar-scanner, netcat compat.
# Registered at tier: tools (.dotfiles-sync.yml), sourced unconditionally;
# each block guards on `command -v`. No installer exists for ClamAV in the
# precursor repo (assumed package-managed).
# Ported from workbench-precursor's tools/security.sh.

# ── ClamAV aliases ────────────────────────────────────────────────────────────
if command -v clamscan &>/dev/null; then
    alias av="sudo clamscan -r"
    alias clam="sudo clamscan -r"
    alias scan="sudo clamscan -r"
    alias clam-home="echo '[INFO] Scanning /home'; sudo nice -n 15 clamscan --bell -i -r /home"
    alias av-home="echo '[INFO] Scanning /home'; sudo nice -n 15 clamscan --bell -i -r /home"
    alias clam-update="sudo freshclam"
    alias av-update="sudo freshclam"
fi

# ── Sonar scanner ─────────────────────────────────────────────────────────────
# A function, not an alias with the token baked in at definition time — an
# alias like `alias sq="sonar-scanner -Dsonar.token=$(secret-tool lookup ...)"`
# evaluates the command substitution once, when the file is sourced, and
# bakes that token into the alias for the rest of the shell session, even if
# the secret rotates. A function re-reads it on every invocation instead.
if command -v sonar-scanner &>/dev/null; then
    sq() {
        sonar-scanner -Dsonar.token="$(secret-tool lookup service sonarqube account scanner 2>/dev/null)" -X "$@"
    }
fi

# ── netcat compatibility ──────────────────────────────────────────────────────
if command -v nc &>/dev/null; then
    alias netcat="nc"
    alias telnet="nc"
fi

get-security-functions() {
    local _dir; _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _get_functions_in "Security functions" "" "${_dir}/security.sh" "${_dir}/disk-encryption.sh"
    _get_aliases_in "Security aliases" "" "${_dir}/security.sh"
}
