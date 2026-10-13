#!/usr/bin/env bash
# tests/check-unverified-downloads.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Covers the pacman Bitwarden
# AppImage (now verified through _bitwarden_desktop_fetch_verified) and the
# 1Password CLI binary fallback's version handling. curl and core helpers are
# stubbed; no network is used.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# ── Static ───────────────────────────────────────────────────────────────────

if grep -n 'bitwarden.com/download' "${INSTALLERS}" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then
    fail "installers.sh still downloads from a bitwarden.com redirect"
else
    ok "no download through a bitwarden.com redirect remains"
fi
if grep -n 'curl -s ' "${INSTALLERS}" >/dev/null; then
    fail "installers.sh still has a 'curl -s ' (no -f)"
else
    ok "no 'curl -s ' without -f remains"
fi

# ── Stubs ────────────────────────────────────────────────────────────────────

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
mkdir -p "${STUBS}"
# shellcheck disable=SC2016  # ${VERSION_HTML} must expand in the stub, not here
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${VERSION_HTML}"\n' > "${STUBS}/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS}/unzip"
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}"
export HOME="${WORK}/home"
mkdir -p "${HOME}"

# shellcheck disable=SC2329  # called by the sourced installers.sh
log_info() { :; }
# shellcheck disable=SC2329
log_warn() { :; }
# shellcheck disable=SC2329
log_error() { :; }
DOWNLOADED=""
# shellcheck disable=SC2329
_download_file_robust() { DOWNLOADED="$1"; : > "$2"; return 0; }
# shellcheck disable=SC1090
source "${INSTALLERS}"

# ── AppImage pattern ─────────────────────────────────────────────────────────

export WORKBENCH_ARCH=x86_64
pat="$(_bitwarden_desktop_pattern appimage)"
if [[ "${pat}" == 'x86_64\.AppImage$' ]]; then ok "x86_64 AppImage pattern is x86_64\\.AppImage\$"; else fail "unexpected AppImage pattern '${pat}'"; fi
export WORKBENCH_ARCH=aarch64
if _bitwarden_desktop_pattern appimage >/dev/null 2>&1; then
    fail "aarch64 should have no AppImage pattern (none is built for arm64)"
else
    ok "aarch64 has no AppImage pattern"
fi

# ── op binary fallback: version handling ─────────────────────────────────────

export WORKBENCH_ARCH=x86_64
html() { printf '<li class="x"><span class="version">%s</span></li>' "$1"; }

VERSION_HTML="$(html '2.39.0')" DOWNLOADED=""
export VERSION_HTML
_op-install-binary >/dev/null 2>&1
if [[ "${DOWNLOADED}" == "https://cache.agilebits.com/dist/1P/op2/pkg/v2.39.0/op_linux_amd64_v2.39.0.zip" ]]; then
    ok "a plain version builds the expected download URL"
else
    fail "a plain version gave URL '${DOWNLOADED}'"
fi

# shellcheck disable=SC2016  # literal hostile strings, not expansions
for bad in '2.39.0/../../x' '2.39.0;touch' '$(id)' '..' '2.' '.2' 'v2.39.0' ''; do
    VERSION_HTML="$(html "${bad}")"; export VERSION_HTML
    DOWNLOADED=""
    _op-install-binary >/dev/null 2>&1
    rc=$?
    if [[ ${rc} -ne 0 && -z "${DOWNLOADED}" ]]; then
        ok "version '${bad}' is rejected before any download"
    else
        fail "version '${bad}' was not rejected (rc=${rc}, url '${DOWNLOADED}')"
    fi
done

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
