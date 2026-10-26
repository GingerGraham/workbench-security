#!/usr/bin/env bash
# shell/security.sh — workbench-security
# Security tool configuration — ClamAV, sonar-scanner, netcat compat.
# Registered at tier: tools (workbench.yml), sourced unconditionally;
# each block guards on `command -v`. No installer exists for ClamAV in the
# precursor repo (assumed package-managed).
# Ported from workbench-precursor's tools/security.sh.

# Availability (workbench-core docs/module-authoring.md). The names below are
# defined only when their tool exists, but listings read this file
# statically, so each one declares what it needs.
_wb_declare_availability clamscan      av clam scan clam-home av-home
_wb_declare_availability freshclam     clam-update av-update
_wb_declare_availability sonar-scanner sq
_wb_declare_availability nc            netcat telnet

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
# The token goes in SONAR_TOKEN in the scanner's environment, not
# -Dsonar.token=<token> in its argv (security review M5).
if command -v sonar-scanner &>/dev/null; then
    # SonarScanner reads SONAR_TOKEN natively.
    sq() {
        SONAR_TOKEN="$(secret-tool lookup service sonarqube account scanner 2>/dev/null)" sonar-scanner -X "$@"
    }
fi

# ── netcat compatibility ──────────────────────────────────────────────────────
if command -v nc &>/dev/null; then
    alias netcat="nc"
    alias telnet="nc"
fi
