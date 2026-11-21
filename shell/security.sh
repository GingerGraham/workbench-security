#!/usr/bin/env bash
# shell/security.sh — workbench-security
# Security tool configuration — ClamAV, sonar-scanner and its keyring token
# helpers, netcat compat.
# Registered at tier: tools (workbench.yml), sourced unconditionally;
# each block guards on `command -v`. No installer exists for ClamAV in the
# precursor repo (assumed package-managed).
# Ported from workbench-precursor's tools/security.sh.

# Availability (workbench-core docs/guide/module-authoring.md). The names below are
# defined only when their tool exists, but listings read this file
# statically, so each one declares what it needs.
_wb_declare_availability clamscan      av clam scan clam-home av-home
_wb_declare_availability freshclam     clam-update av-update
_wb_declare_availability sonar-scanner sq
_wb_declare_availability secret-tool   sonar-token-set sonar-token-get sonar-token-clear
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

# ── SonarQube token (keyring) ─────────────────────────────────────────────────
# The token lives in the desktop keyring (libsecret), under these attributes.
# Same values as _SONAR_TOKEN_SERVICE/_ACCOUNT in shell/installers.sh, which
# is sourced separately; tests/check-sonar.sh asserts they match.
_sonar_token_service="sonarqube"
_sonar_token_account="scanner"

# Prints the stored token, or nothing. No message: `sq` calls this on every run.
_sonar_token_lookup() {
    secret-tool lookup service "${_sonar_token_service}" account "${_sonar_token_account}" 2>/dev/null
}

# Stores a token read from the terminal (hidden) or stdin. It reaches
# secret-tool on stdin, never in an argument list.
sonar-token-set() {
    if ! command -v secret-tool &>/dev/null; then
        log_error "secret-tool not found — install it with: wb tools install secret-tool"
        return 1
    fi
    local token
    printf 'SonarQube token (input hidden): ' >&2
    IFS= read -r -s token || { printf '\n' >&2; return 1; }
    printf '\n' >&2
    if [[ -z "${token}" ]]; then
        log_error "No token entered — nothing stored"
        return 1
    fi
    printf '%s' "${token}" | secret-tool store --label="SonarQube token" \
        service "${_sonar_token_service}" account "${_sonar_token_account}"
    local rc=$?
    token=""
    return ${rc}
}

# Prints the stored token. Meant for capturing, e.g.
# SONAR_TOKEN="$(sonar-token-get)" some-command
sonar-token-get() {
    if ! command -v secret-tool &>/dev/null; then
        log_error "secret-tool not found — install it with: wb tools install secret-tool"
        return 1
    fi
    local token
    token="$(_sonar_token_lookup)"
    if [[ -z "${token}" ]]; then
        log_error "No SonarQube token stored — store one with: sonar-token-set"
        return 1
    fi
    if [[ -t 1 ]]; then
        printf '%s\n' "${token}"
    else
        printf '%s' "${token}"
    fi
}

sonar-token-clear() {
    if ! command -v secret-tool &>/dev/null; then
        log_error "secret-tool not found — install it with: wb tools install secret-tool"
        return 1
    fi
    secret-tool clear service "${_sonar_token_service}" account "${_sonar_token_account}"
}

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
        SONAR_TOKEN="$(_sonar_token_lookup)" sonar-scanner -X "$@"
    }
fi

# ── netcat compatibility ──────────────────────────────────────────────────────
if command -v nc &>/dev/null; then
    alias netcat="nc"
    alias telnet="nc"
fi
