#!/usr/bin/env bash
# tests/check-empty-array-expansions.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). bash < 4.4 under `set -u` treats
# "${arr[@]}" of an empty array as an unbound variable. This suite (1) checks
# statically that every array that can be empty in shell/ is expanded with the
# ${arr[@]+"${arr[@]}"} idiom, and (2) runs _tpm_enroll_device under `set -u`
# with every combination of the optional flag arrays and checks the exact
# systemd-cryptenroll argv. (Step 2 cannot itself reproduce the old-bash
# failure on a newer bash; step 1 is what guards it.)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISK="${REPO_ROOT}/shell/disk-encryption.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# ── Static ───────────────────────────────────────────────────────────────────

# Arrays declared empty (name=() / local name=()) in shell/ may be empty at use.
empty_arrays="$(grep -rhoE '(^|[[:space:]])(local )?[A-Za-z_][A-Za-z0-9_]*=\(\)' "${REPO_ROOT}/shell" \
                | sed -E 's/^[[:space:]]*(local )?//; s/=\(\)$//' | sort -u)"
while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    # A bare "${name[@]}" outside a for-loop header is the risky form.
    bare="$(grep -rnE "\"\\\$\{${name}\[@\]\}\"" "${REPO_ROOT}/shell" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*for |\[@\]\+' || true)"
    if [[ -z "${bare}" ]]; then
        ok "array '${name}' is never expanded bare outside a for-loop"
    else
        fail "array '${name}' has a bare \"\${${name}[@]}\" expansion: ${bare}"
    fi
done <<< "${empty_arrays}"

for name in wipe_flag pin_flag; do
    if grep -qF "\${${name}[@]+\"\${${name}[@]}\"}" "${DISK}"; then
        ok "${name} uses the \${${name}[@]+\"\${${name}[@]}\"} idiom"
    else
        fail "${name} does not use the empty-safe expansion idiom"
    fi
done

# ── Behaviour under set -u ───────────────────────────────────────────────────

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin"
# sudo stub: records the argv it is given (the systemd-cryptenroll command).
# shellcheck disable=SC2016  # ${ARGV_OUT} must expand in the stub, not here
printf '#!/usr/bin/env bash\nprintf "%%s " "$@" > "${ARGV_OUT}"\nexit 0\n' > "${WORK}/bin/sudo"
chmod +x "${WORK}/bin/sudo"
export PATH="${WORK}/bin:${PATH}"
export ARGV_OUT="${WORK}/argv"

# shellcheck disable=SC2329  # called by the sourced disk-encryption.sh
log_info() { :; }
# shellcheck disable=SC2329
log_warn() { :; }
# shellcheck disable=SC2329
log_error() { :; }
# shellcheck disable=SC2329
_wb_alias_availability() { :; }
export WORKBENCH_OS=Linux
# shellcheck disable=SC1090
source "${DISK}"

# Defined after sourcing, which would otherwise replace them with the real ones.
# shellcheck disable=SC2329  # called by _tpm_enroll_device
_tpm_ensure_recovery_key() { return 0; }
# shellcheck disable=SC2329
_tpm_show_slots() { return 0; }
# shellcheck disable=SC2329
_tpm_has_token_type() { [[ "${HAS_TPM2:-no}" == "yes" ]]; }
# The existing TPM2 token has no PIN, so nothing asks (the PIN question is
# covered in tests/check-disk-encryption-guards.sh).
# shellcheck disable=SC2329
_tpm_tpm2_pin_state() { return 1; }

run_case() {   # <has_tpm2 yes|no> <with_pin true|false> <expected argv>
    HAS_TPM2="$1"
    : > "${ARGV_OUT}"
    _tpm_enroll_device /dev/fake "$2"
    local rc=$? got
    got="$(cat "${ARGV_OUT}")"
    if [[ ${rc} -eq 0 && "${got}" == "$3" ]]; then
        ok "tpm2 present=$1 with_pin=$2 -> ${got}"
    else
        fail "tpm2 present=$1 with_pin=$2: rc=${rc}, argv '${got}', expected '$3'"
    fi
}

base='systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+2+5+7 /dev/fake '
run_case no  false "${base}"
run_case no  true  "systemd-cryptenroll --tpm2-with-pin=yes --tpm2-device=auto --tpm2-pcrs=0+2+5+7 /dev/fake "
run_case yes false "systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=0+2+5+7 /dev/fake "
run_case yes true  "systemd-cryptenroll --wipe-slot=tpm2 --tpm2-with-pin=yes --tpm2-device=auto --tpm2-pcrs=0+2+5+7 /dev/fake "

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
