#!/usr/bin/env bash
# tests/check-apt-keyring-pinning.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Verifies the 1Password Debian
# install paths trust only the pinned key (workbench-core D79): the apt and
# debsig keyrings come from core's pinned-key helpers with the pinned
# fingerprint, and no `gpg --dearmor` of an unverified download remains for
# 1Password. Core helpers and system commands are stubbed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

FPR="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"

# ── Static ───────────────────────────────────────────────────────────────────

# Only the Trivy deb path may still dearmor (Aqua publishes no fingerprint).
n="$(grep -c 'gpg --dearmor' "${INSTALLERS}")"
if [[ "${n}" -eq 1 ]] && grep 'gpg --dearmor' "${INSTALLERS}" | grep -q 'tee /usr/share/keyrings/trivy.gpg'; then
    ok "the only remaining gpg --dearmor is the Trivy deb key (no published fingerprint)"
else
    fail "unexpected gpg --dearmor in installers.sh (${n} occurrences)"
fi

# ── Stubbed run ──────────────────────────────────────────────────────────────

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}"
: > "${CALLS}"

# System commands: record and succeed. tee swallows stdin.
for c in install apt-get dpkg; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n[[ "%s" == dpkg ]] && echo amd64\nexit 0\n' "${c}" "${CALLS}" "${c}" > "${STUBS}/${c}"
done
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "${STUBS}/tee"
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}"

# Core helpers, as named in the files under test.
# shellcheck disable=SC2329  # called by the sourced installers.sh
log_info() { :; }
# shellcheck disable=SC2329
log_error() { :; }
# shellcheck disable=SC2329
get-elevation-command() { echo ""; }
# shellcheck disable=SC2329
_wb_apt_keyring_pinned() { echo "apt_keyring_pinned $*" >> "${CALLS}"; return "${STUB_APT_RC:-0}"; }
# shellcheck disable=SC2329
_download_file_robust() { echo "download $1" >> "${CALLS}"; : > "$2"; }
# shellcheck disable=SC2329
_wb_key_extract_pinned() { echo "extract_pinned $3 $4" >> "${CALLS}"; : > "$2"; return "${STUB_EXTRACT_RC:-0}"; }
# shellcheck disable=SC1090
source "${INSTALLERS}"

for fn in _1password-install-debian _op-install-debian; do
    : > "${CALLS}"
    "${fn}"
    rc=$?
    if [[ ${rc} -eq 0 ]]; then ok "${fn} succeeds with stubbed helpers"; else fail "${fn} returned ${rc}"; fi
    if grep -q "^apt_keyring_pinned https://downloads.1password.com/linux/keys/1password.asc /usr/share/keyrings/1password-archive-keyring.gpg ${FPR}\$" "${CALLS}"; then
        ok "${fn} installs the apt keyring through _wb_apt_keyring_pinned with the pinned fingerprint"
    else
        fail "${fn} did not call _wb_apt_keyring_pinned with the pinned fingerprint"
    fi
done

# The desktop path also installs the debsig keyring, pinned.
: > "${CALLS}"
_1password-install-debian
if grep -q "^extract_pinned binary ${FPR}\$" "${CALLS}" && grep -q 'debsig/keyrings/AC2D62742012EA22/debsig.gpg' "${CALLS}"; then
    ok "the debsig keyring is filtered to the pinned fingerprint before install"
else
    fail "the debsig keyring was not installed from a pinned extract"
fi

# Fail closed: a rejected key aborts before apt is touched.
: > "${CALLS}"
STUB_APT_RC=1 _1password-install-debian
rc=$?
if [[ ${rc} -ne 0 ]] && ! grep -q '^apt-get' "${CALLS}"; then
    ok "a rejected apt key aborts before apt-get runs (desktop)"
else
    fail "desktop path continued after the apt key was rejected (rc=${rc})"
fi
: > "${CALLS}"
STUB_APT_RC=1 _op-install-debian
rc=$?
if [[ ${rc} -ne 0 ]] && ! grep -q '^apt-get' "${CALLS}"; then
    ok "a rejected apt key aborts before apt-get runs (CLI)"
else
    fail "CLI path continued after the apt key was rejected (rc=${rc})"
fi
: > "${CALLS}"
STUB_EXTRACT_RC=1 _1password-install-debian
rc=$?
if [[ ${rc} -ne 0 ]] && ! grep -q '^apt-get' "${CALLS}"; then
    ok "a rejected debsig key aborts before apt-get runs"
else
    fail "desktop path continued after the debsig key was rejected (rc=${rc})"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
