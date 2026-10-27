#!/usr/bin/env bash
# tests/check-op-zip-verify.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). The 1Password CLI zip fallback
# (_op-install-binary) installs op only when the op.sig inside the zip
# verifies against the pinned 1Password key, and returns 0 on success even
# when ~/.local/bin is already on PATH (N21). curl, unzip, gpgv and the core
# helpers are stubbed; PATH holds only the stubs and a few real utilities, so
# "gpgv absent" is real. No network is used.
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

if grep -q 'KNOWN GAP' "${INSTALLERS}"; then
    fail "installers.sh still marks a download as a KNOWN GAP (unverified)"
else
    ok "no download in installers.sh is marked as a known unverified gap"
fi

# ── Stubs ────────────────────────────────────────────────────────────────────

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
TOOLS="${WORK}/tools"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}" "${TOOLS}"

for t in bash sed head grep mktemp rm mkdir install cat; do
    real="$(command -v "${t}")" || { echo "FAIL: test needs ${t}"; exit 1; }
    ln -s "${real}" "${TOOLS}/${t}"
done

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "<li class=\\"x\\"><span class=\\"version\\">2.39.0</span></li>"\n' > "${STUBS}/curl"
# unzip -q <zip> -d <dir>: unpacks op, and op.sig unless STUB_NO_SIG is set.
cat > "${STUBS}/unzip" <<STUB
#!/usr/bin/env bash
echo "unzip \$*" >> "${CALLS}"
dir="\$4"
mkdir -p "\${dir}"
printf '#!/bin/sh\necho op\n' > "\${dir}/op"
[[ -n "\${STUB_NO_SIG:-}" ]] || printf 'sig' > "\${dir}/op.sig"
exit 0
STUB
cat > "${STUBS}/gpgv" <<STUB
#!/usr/bin/env bash
echo "gpgv \$*" >> "${CALLS}"
[[ -n "\${STUB_GPGV_FAIL:-}" ]] && { echo "gpgv: BAD signature" >&2; exit 1; }
exit 0
STUB
chmod +x "${STUBS}"/*

# shellcheck disable=SC2329  # called by the sourced installers.sh
log_info() { :; }
# shellcheck disable=SC2329
log_warn() { :; }
# shellcheck disable=SC2329
log_error() { :; }
# shellcheck disable=SC2329
_download_file_robust() { echo "download $1" >> "${CALLS}"; : > "$2"; }
# shellcheck disable=SC2329
_wb_key_extract_pinned() { echo "extract_pinned $3 $4" >> "${CALLS}"; : > "$2"; }
# shellcheck disable=SC1090
source "${INSTALLERS}"

export WORKBENCH_ARCH=x86_64

# run_case <label>: runs _op-install-binary in a fresh HOME with the current
# STUB_* settings; sets rc.
run_case() {
    export HOME="${WORK}/home-$1"
    rm -rf "${HOME}"; mkdir -p "${HOME}"
    : > "${CALLS}"
    ( PATH="${STUB_PATH}"; _op-install-binary ) >/dev/null 2>&1
    rc=$?
}

STUB_PATH="${STUBS}:${TOOLS}"

# Good signature, ~/.local/bin already on PATH: installs and returns 0.
unset STUB_NO_SIG STUB_GPGV_FAIL
export HOME="${WORK}/home-good"
STUB_PATH="${STUBS}:${TOOLS}:${HOME}/.local/bin"
run_case good
if [[ ${rc} -eq 0 && -x "${HOME}/.local/bin/op" ]]; then
    ok "a good signature installs op and returns 0 with ~/.local/bin on PATH"
else
    fail "good signature: rc=${rc}, op installed: $([[ -x "${HOME}/.local/bin/op" ]] && echo yes || echo no)"
fi
if grep -q "^extract_pinned binary ${FPR}\$" "${CALLS}" \
    && grep -q '^download https://downloads.1password.com/linux/keys/1password.asc$' "${CALLS}" \
    && grep -qE '^gpgv --keyring .*/pinned\.gpg .*/zip/op\.sig .*/zip/op$' "${CALLS}"; then
    ok "the signature is checked with gpgv against the pinned 1Password key"
else
    fail "the pinned-key gpgv check did not run as expected: $(tr '\n' ';' < "${CALLS}")"
fi
STUB_PATH="${STUBS}:${TOOLS}"

# gpgv rejects the signature.
export STUB_GPGV_FAIL=1
run_case badsig
if [[ ${rc} -ne 0 && ! -e "${HOME}/.local/bin/op" ]]; then
    ok "a failed gpgv check returns 1 and installs nothing"
else
    fail "bad signature: rc=${rc}, op installed: $([[ -e "${HOME}/.local/bin/op" ]] && echo yes || echo no)"
fi
unset STUB_GPGV_FAIL

# op.sig missing from the zip.
export STUB_NO_SIG=1
run_case nosig
if [[ ${rc} -ne 0 && ! -e "${HOME}/.local/bin/op" ]] && ! grep -q '^gpgv' "${CALLS}"; then
    ok "a zip without op.sig returns 1 and installs nothing"
else
    fail "missing op.sig: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
unset STUB_NO_SIG

# gpgv not installed: fails before any download.
mv "${STUBS}/gpgv" "${WORK}/gpgv.off"
run_case nogpgv
if [[ ${rc} -ne 0 && ! -e "${HOME}/.local/bin/op" ]] && ! grep -q '^download' "${CALLS}"; then
    ok "without gpgv it returns 1 before any download"
else
    fail "gpgv absent: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
mv "${WORK}/gpgv.off" "${STUBS}/gpgv"

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
