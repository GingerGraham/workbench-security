#!/usr/bin/env bash
# tests/check-trivy-repo.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Checks on the Trivy repository
# definitions: both pin the Trivy signing key (_TRIVY_KEY_FPR) through core's
# pinned-key helpers (workbench-core D79), the rpm repo is limited to the
# trivy package, both are rewritten on every run, a served key without the
# pinned fingerprint stops both paths with nothing written, and the release
# lookup fails on HTTP errors.
#
# Core's _wb_dnf_vendor_repo and _wb_apt_keyring_pinned are stubbed (module
# CI runs without core): each stub "downloads" a served-key fixture, accepts
# it only if it carries the fingerprint it was given, and only then writes
# under _WB_TEST_SYSROOT, in core's own repo-file format. Core's real
# helpers are tested against real keys in core's
# tests/check-vendor-key-trust.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

INSTALLERS="${REPO_ROOT}/shell/installers.sh"
FPR="825AD9036F7C850E6A6FED4935B8ACA44FD9CA9F"

# ── Static ───────────────────────────────────────────────────────────────────

if grep -q "^_TRIVY_KEY_FPR=\"${FPR}\"" "${INSTALLERS}"; then
    ok "_TRIVY_KEY_FPR is pinned to ${FPR}"
else
    fail "_TRIVY_KEY_FPR is not pinned to ${FPR}"
fi

if grep -nE 'gpgkey=https' "${INSTALLERS}" >/dev/null; then
    fail "installers.sh still has a remote gpgkey=https://…"
else
    ok "no remote gpgkey=https://… in installers.sh"
fi

if grep -nE 'trivy\.repo|aquasecurity.*\| *gpg --dearmor|wget -qO' "${INSTALLERS}" >/dev/null; then
    fail "installers.sh still writes trivy.repo itself or dearmors an unverified Trivy key"
else
    ok "the Trivy repo file and keyring are written only through core's pinned-key helpers"
fi

deb_body="$(awk '/^_trivy-repo-deb\(\) \{/{f=1} f{print} f && /^\}/{exit}' "${INSTALLERS}")"
if [[ -z "${deb_body}" ]]; then
    fail "_trivy-repo-deb not found"
elif printf '%s\n' "${deb_body}" | grep -q 'return 0'; then
    fail "_trivy-repo-deb still returns early (an existing trivy.list would skip the pinned keyring)"
else
    ok "_trivy-repo-deb has no early return, so it runs again when trivy.list exists"
fi

if grep -E 'curl -s ' "${INSTALLERS}" | grep -q 'aquasecurity/trivy'; then
    fail "the Trivy release lookup still uses curl -s"
else
    ok "the Trivy release lookup does not use curl -s"
fi

if grep -q 'curl -fsS https://api.github.com/repos/aquasecurity/trivy/releases/latest' "${INSTALLERS}"; then
    ok "the Trivy release lookup uses curl -fsS"
else
    fail "the Trivy release lookup does not use curl -fsS"
fi

# ── Stubbed runs ─────────────────────────────────────────────────────────────

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# run_repo <rpm|deb> <served-fingerprint> <check-update-rc> <dnf|yum>
# Runs _trivy-repo-<kind> in a subshell with stub dnf/yum/apt-get/tee and
# stub core helpers, against a fresh sysroot at ${WORK}/root. The served key
# carries <served-fingerprint>. Prints the function's exit status; the call
# log is ${WORK}/calls.
run_repo() {
    local kind="$1" served="$2" rc_in="$3" mgr="$4"
    rm -rf "${WORK:?}/root" "${WORK:?}/bin"
    mkdir -p "${WORK}/root" "${WORK}/bin"
    : > "${WORK}/calls"
    printf '%s\n' "${served}" > "${WORK}/served-key"
    (
        STUBS="${WORK}/bin"
        CALLS="${WORK}/calls"
        for c in dnf yum apt-get; do
            printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit %s\n' "${c}" "${CALLS}" "${rc_in}" > "${STUBS}/${c}"
        done
        printf '#!/usr/bin/env bash\necho "tee $*" >> "%s"\ncat >/dev/null\n' "${CALLS}" > "${STUBS}/tee"
        chmod +x "${STUBS}"/*
        [[ "${mgr}" == "yum" ]] && rm -f "${STUBS}/dnf"
        # A PATH of only the stubs plus the bare utilities the function needs.
        PATH="${STUBS}:/usr/bin:/bin"
        export _WB_TEST_SYSROOT="${WORK}/root"
        # shellcheck disable=SC2329  # shadows the builtin for the sourced function
        [[ "${mgr}" == "yum" ]] && command() { if [[ "$1" == "-v" && "$2" == "dnf" ]]; then return 1; fi; builtin command "$@"; }
        # shellcheck disable=SC2329  # called by the sourced installers.sh
        get-elevation-command() { echo ""; }
        # shellcheck disable=SC2329
        log_info() { :; }
        # shellcheck disable=SC2329
        log_error() { :; }
        # shellcheck disable=SC2329
        _served_key_matches() { grep -qx "$1" "${WORK}/served-key"; }
        # shellcheck disable=SC2329
        _wb_dnf_vendor_repo() {
            echo "dnf_vendor_repo $*" >> "${CALLS}"
            local id="" name="" baseurl="" fpr="" pkgs="" gpgc=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --repo-gpgcheck) gpgc=1; shift; continue ;;
                    --id) id="$2" ;; --name) name="$2" ;; --baseurl) baseurl="$2" ;;
                    --fingerprint) fpr="$2" ;; --include) pkgs="${pkgs:+${pkgs} }$2" ;;
                esac
                shift 2
            done
            _served_key_matches "${fpr}" || return 1
            mkdir -p "${_WB_TEST_SYSROOT}/etc/pki/rpm-gpg" "${_WB_TEST_SYSROOT}/etc/yum.repos.d"
            : > "${_WB_TEST_SYSROOT}/etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-${id}"
            printf '%s\n' "[${id}]" "name=${name}" "baseurl=${baseurl}" "enabled=1" "gpgcheck=1" \
                "repo_gpgcheck=${gpgc}" "gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-${id}" \
                "includepkgs=${pkgs}" > "${_WB_TEST_SYSROOT}/etc/yum.repos.d/${id}.repo"
        }
        # shellcheck disable=SC2329
        _wb_apt_keyring_pinned() {
            echo "apt_keyring_pinned $*" >> "${CALLS}"
            _served_key_matches "$3" || return 1
            mkdir -p "${_WB_TEST_SYSROOT}$(dirname "$2")"
            : > "${_WB_TEST_SYSROOT}$2"
        }
        # shellcheck disable=SC1090
        source "${INSTALLERS}"
        "_trivy-repo-${kind}" >/dev/null 2>&1
        echo $?
    )
}

# rpm: the repo definition.
got="$(run_repo rpm "${FPR}" 0 dnf)"
repo_file="${WORK}/root/etc/yum.repos.d/trivy.repo"
if [[ "${got}" == "0" && -f "${repo_file}" ]]; then ok "_trivy-repo-rpm writes trivy.repo with the pinned key served"; else fail "_trivy-repo-rpm gave ${got}, repo file present: $([[ -f "${repo_file}" ]] && echo yes || echo no)"; fi
calls="$(cat "${WORK}/calls")"
for want in '--id trivy' "--fingerprint ${FPR}" '--include trivy' \
            '--key-url https://aquasecurity.github.io/trivy-repo/rpm/public.key'; do
    case "${calls}" in
        *"${want}"*) ok "_trivy-repo-rpm passes ${want}" ;;
        *) fail "_trivy-repo-rpm did not pass ${want} (got: ${calls})" ;;
    esac
done
case "${calls}" in
    *--repo-gpgcheck*) fail "_trivy-repo-rpm passes --repo-gpgcheck (the repo publishes no repomd.xml.asc)" ;;
    *) ok "_trivy-repo-rpm does not pass --repo-gpgcheck" ;;
esac
# shellcheck disable=SC2016  # literal $basearch is the point
basearch_url='trivy-repo/rpm/releases/$basearch/'
case "${calls}" in
    *"${basearch_url}"*) ok "baseurl keeps a literal \$basearch for dnf" ;;
    *) fail "baseurl does not keep a literal \$basearch (got: ${calls})" ;;
esac
if grep -qx 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-workbench-trivy' "${repo_file}" 2>/dev/null \
    && grep -qx 'includepkgs=trivy' "${repo_file}" 2>/dev/null \
    && ! grep -q '^gpgkey=https' "${repo_file}" 2>/dev/null; then
    ok "trivy.repo has gpgkey=file://…, includepkgs=trivy and no https gpgkey"
else
    fail "trivy.repo is not pinned and allowlisted: $(tr '\n' ' ' < "${repo_file}" 2>/dev/null)"
fi

# rpm: wrong served key.
got="$(run_repo rpm 0000000000000000000000000000000000000000 0 dnf)"
if [[ "${got}" == "1" ]] && [[ -z "$(find "${WORK}/root" -type f)" ]] && ! grep -q '^dnf ' "${WORK}/calls"; then
    ok "a served key without the pinned fingerprint fails the rpm path with nothing written and no dnf run"
else
    fail "rpm path with an unpinned key: rc=${got}, files: $(find "${WORK}/root" -type f | tr '\n' ' '), calls: $(tr '\n' ';' < "${WORK}/calls")"
fi

# rpm: check-update exit codes.
for mgr in dnf yum; do
    got="$(run_repo rpm "${FPR}" 0 "${mgr}")"
    if [[ "${got}" == "0" ]]; then ok "${mgr} check-update exit 0 is success"; else fail "${mgr} check-update exit 0 gave ${got}"; fi
    got="$(run_repo rpm "${FPR}" 100 "${mgr}")"
    if [[ "${got}" == "0" ]]; then ok "${mgr} check-update exit 100 (updates available) is success"; else fail "${mgr} check-update exit 100 gave ${got}"; fi
    got="$(run_repo rpm "${FPR}" 1 "${mgr}")"
    if [[ "${got}" == "1" ]]; then ok "${mgr} check-update exit 1 is propagated as failure"; else fail "${mgr} check-update exit 1 gave ${got}, expected 1"; fi
done

# deb: pinned keyring, then the sources list.
got="$(run_repo deb "${FPR}" 0 dnf)"
if [[ "${got}" == "0" ]] \
    && grep -qx "apt_keyring_pinned https://aquasecurity.github.io/trivy-repo/deb/public.key /usr/share/keyrings/trivy.gpg ${FPR}" "${WORK}/calls"; then
    ok "_trivy-repo-deb installs the keyring through _wb_apt_keyring_pinned with the pinned fingerprint"
else
    fail "_trivy-repo-deb gave ${got}; calls: $(tr '\n' ';' < "${WORK}/calls")"
fi
if grep -qx 'tee /etc/apt/sources.list.d/trivy.list' "${WORK}/calls" && grep -q '^apt-get update' "${WORK}/calls"; then
    ok "_trivy-repo-deb writes trivy.list and refreshes apt after the pinned keyring"
else
    fail "_trivy-repo-deb did not write trivy.list and run apt-get update; calls: $(tr '\n' ';' < "${WORK}/calls")"
fi

# deb: wrong served key.
got="$(run_repo deb 0000000000000000000000000000000000000000 0 dnf)"
if [[ "${got}" == "1" ]] && [[ -z "$(find "${WORK}/root" -type f)" ]] \
    && ! grep -q '^tee' "${WORK}/calls" && ! grep -q '^apt-get' "${WORK}/calls"; then
    ok "a served key without the pinned fingerprint fails the deb path with nothing written and no apt-get run"
else
    fail "deb path with an unpinned key: rc=${got}, calls: $(tr '\n' ';' < "${WORK}/calls")"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
