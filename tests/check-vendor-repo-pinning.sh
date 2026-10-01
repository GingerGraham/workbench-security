#!/usr/bin/env bash
# tests/check-vendor-repo-pinning.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Verifies the 1Password install
# paths trust only the pinned local key (workbench-core D79): no unverified
# `rpm --import <url>`, no --gpg-auto-import-keys, and the repo definition is
# written through core's _wb_dnf_vendor_repo with the pinned fingerprint and
# an allowlist. Core helpers are stubbed, so no root or network is needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

INSTALLERS="${REPO_ROOT}/shell/installers.sh"

# ── Static checks ────────────────────────────────────────────────────────────

if grep -rnE 'gpg-auto-import-keys|rpm --import https' "${REPO_ROOT}/shell" >/dev/null; then
    fail "shell/ still has --gpg-auto-import-keys or an unverified rpm --import <url>"
else
    ok "no --gpg-auto-import-keys and no unverified rpm --import <url> in shell/"
fi

# shellcheck disable=SC2016  # literal source text, not an expansion
n="$(grep -c '_wb_rpm_import_pinned_key "${_1PASSWORD_KEY_URL}" 1password "${_1PASSWORD_KEY_FPR}"' "${INSTALLERS}")"
if [[ "${n}" -eq 2 ]]; then
    ok "both SUSE paths import the pinned 1Password key"
else
    fail "expected 2 pinned-key imports for SUSE, found ${n}"
fi

n="$(grep -c 'zypper --non-interactive refresh 1password' "${INSTALLERS}")"
if [[ "${n}" -eq 2 ]]; then
    ok "both SUSE paths refresh with --non-interactive"
else
    fail "expected 2 'zypper --non-interactive refresh 1password', found ${n}"
fi

n="$(grep -c '^    _1password_repo_rhel || return 1' "${INSTALLERS}")"
if [[ "${n}" -eq 2 ]]; then
    ok "both RHEL paths write the repo through _1password_repo_rhel"
else
    fail "expected 2 _1password_repo_rhel callers, found ${n}"
fi

if grep -E 'gpgkey=' "${INSTALLERS}" | grep -q 'downloads\.1password\.com'; then
    fail "a 1Password repo definition still uses a remote gpgkey="
else
    ok "no remote 1Password gpgkey= in any repo definition"
fi

# ── _1password_repo_rhel arguments ───────────────────────────────────────────

# Core API stubs, as named in the files under test.
# shellcheck disable=SC2329  # called by the sourced installers.sh
log_info() { :; }
# shellcheck disable=SC2329
log_error() { :; }
captured=""
# shellcheck disable=SC2329
_wb_dnf_vendor_repo() { captured="$*"; }
# shellcheck disable=SC1090
source "${INSTALLERS}"

_1password_repo_rhel
for want in '--id 1password' '--fingerprint 3FEF9748469ADBE15DA7CA80AC2D62742012EA22' \
            '--include 1password ' '--include 1password-cli' '--repo-gpgcheck' \
            '--key-url https://downloads.1password.com/linux/keys/1password.asc'; do
    case "${captured}" in
        *"${want}"*) ok "_1password_repo_rhel passes ${want}" ;;
        *) fail "_1password_repo_rhel did not pass ${want} (got: ${captured})" ;;
    esac
done
# shellcheck disable=SC2016  # literal $basearch is the point
basearch_url='rpm/stable/$basearch'
case "${captured}" in
    *"${basearch_url}"*) ok "baseurl keeps a literal \$basearch for dnf" ;;
    *) fail "baseurl does not keep a literal \$basearch (got: ${captured})" ;;
esac

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
