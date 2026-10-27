#!/usr/bin/env bash
# tests/check-disk-encryption-guards.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Covers shell/disk-encryption.sh
# and shell/security.sh in the user's shell, run for real in bash and, when
# installed, zsh:
#   - availability declarations say what each name needs;
#   - the PTY worker is found in both shells (it was looked up with
#     BASH_SOURCE inside a function, which zsh leaves empty);
#   - INT/TERM while the recovery-key transcript or the 1Password item file
#     exists removes it, restores the caller's trap and re-raises (N17);
#   - an existing TPM2+PIN enrollment is not replaced with TPM2-only without
#     a yes at a terminal, and rotate-luks-key --with-pin enrolls with a PIN.
# Every external tool (sudo, cryptsetup, systemd-cryptenroll, op, python3's
# worker) is stubbed; nothing touches a disk, a TPM or a vault.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISK="${REPO_ROOT}/shell/disk-encryption.sh"
SEC="${REPO_ROOT}/shell/security.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
LOG="${WORK}/log"
mkdir -p "${STUBS}" "${WORK}/run"

SHELLS="bash"
if command -v zsh &>/dev/null; then
    SHELLS="bash zsh"
else
    ok "zsh not installed — zsh runs below are skipped, bash runs still apply"
fi

# sudo: drops -n and runs the command. Each tool the module calls through it
# is a stub below. python3 <worker> <transcript> …: records the call, creates
# the transcript, and, with STUB_INTERRUPT=1, sends INT to the calling shell.
cat > "${STUBS}/sudo" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-n" ]] && shift
echo "sudo $*" >> "${LOG}"
if [[ "$1" == "python3" ]]; then
    echo "transcript $3" >> "${LOG}"
    printf 'recovery key: SENTINEL\n' > "$3"
    [[ "${STUB_INTERRUPT:-}" == "1" ]] && kill -s INT "${PPID}"
    exit "${STUB_WORKER_RC:-0}"
fi
exec "$@"
STUB
# systemd-cryptenroll <dev>: the slot listing, with STUB_TOKENS types.
cat > "${STUBS}/systemd-cryptenroll" <<'STUB'
#!/usr/bin/env bash
echo "systemd-cryptenroll $*" >> "${LOG}"
if [[ $# -eq 1 ]]; then
    echo "SLOT TYPE"
    n=0
    for t in ${STUB_TOKENS:-password}; do echo "   ${n} ${t}"; n=$((n + 1)); done
fi
exit 0
STUB
# cryptsetup luksDump --dump-json-metadata: STUB_JSON, or fail when unset.
cat > "${STUBS}/cryptsetup" <<'STUB'
#!/usr/bin/env bash
echo "cryptsetup $*" >> "${LOG}"
if [[ "$1" == "luksDump" ]]; then
    [[ -n "${STUB_JSON:-}" ]] || exit 1
    printf '%s\n' "${STUB_JSON}"
fi
exit 0
STUB
# op: `item create` with STUB_INTERRUPT=1 sends INT to the calling shell.
cat > "${STUBS}/op" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "item template get" ]]; then
    echo '{"title":"","fields":[{"id":"notesPlain","value":""}]}'
    exit 0
fi
if [[ "$1 $2" == "item create" ]]; then
    echo "op-dir $(dirname "$4")" >> "${LOG}"
    [[ "${STUB_INTERRUPT:-}" == "1" ]] && kill -s INT "${PPID}"
fi
exit 0
STUB
chmod +x "${STUBS}"/*

# Prelude every child shell sources: core stubs, then the module file.
PRELUDE="${WORK}/prelude.sh"
cat > "${PRELUDE}" <<STUB
log_info()  { :; }
log_warn()  { echo "WARN: \$*" >> "${LOG}"; }
log_error() { echo "ERROR: \$*" >> "${LOG}"; }
_str_lower() { printf '%s' "\$1" | tr '[:upper:]' '[:lower:]'; }
sudo-test() { return 0; }
_read_prompt() { echo "asked: \$1" >> "${LOG}"; eval "\$2=\\\${STUB_ANSWER:-}"; }
_wb_alias_availability() { echo "alias_availability \$*" >> "${LOG}"; }
_wb_declare_availability() { echo "declare_availability \$*" >> "${LOG}"; }
export WORKBENCH_OS=Linux
export PATH="${STUBS}:\${PATH}"
export LOG="${LOG}"
export XDG_RUNTIME_DIR="${WORK}/run"
source "${DISK}"
source "${SEC}"
STUB

# in_shell <shell> <script>: runs <script> after the prelude in a fresh
# <shell>; prints its output, returns its status.
in_shell() {
    local sh="$1" body="$2"
    : > "${LOG}"
    printf 'source %s\n%s\n' "${PRELUDE}" "${body}" > "${WORK}/case.sh"
    "${sh}" "${WORK}/case.sh" 2>/dev/null
}

# ── Availability ─────────────────────────────────────────────────────────────

in_shell bash ':' >/dev/null
for want in 'declare_availability clamscan av clam scan clam-home av-home' \
            'declare_availability freshclam clam-update av-update' \
            'declare_availability sonar-scanner sq' \
            'declare_availability nc netcat telnet' \
            'alias_availability --needs cryptsetup, blkid, systemd-cryptenroll, systemctl and python3 (Linux) _tpm_tools_present enroll-luks-tpm2 rotate-luks-key'; do
    if grep -qxF "${want}" "${LOG}"; then ok "declares: ${want}"; else fail "missing declaration: ${want}"; fi
done
# Declared before the Linux guard, so a non-Linux host lists the reason too.
: > "${LOG}"
WORKBENCH_OS=Mac bash -c "source '${PRELUDE}' 2>/dev/null; WORKBENCH_OS=Mac; source '${DISK}'" >/dev/null 2>&1
if grep -q '^alias_availability --needs' "${LOG}"; then
    ok "disk-encryption.sh declares availability before its Linux guard"
else
    fail "disk-encryption.sh declares nothing on a non-Linux host"
fi

# ── PTY worker path ──────────────────────────────────────────────────────────

for sh in ${SHELLS}; do
    # shellcheck disable=SC2016  # expands in the child shell, not here
    out="$(in_shell "${sh}" 'printf "%s\n" "${_de_module_dir}"')"
    if [[ "${out}" == "${REPO_ROOT}" ]]; then
        ok "${sh}: _de_module_dir is the module root"
    else
        fail "${sh}: _de_module_dir is '${out}', expected '${REPO_ROOT}'"
    fi
    STUB_WORKER_RC=1 in_shell "${sh}" '_tpm_ensure_recovery_key /dev/fake' >/dev/null
    if grep -qF "sudo python3 ${REPO_ROOT}/workers/disk-encryption-pty-capture.py " "${LOG}" \
        && ! grep -q 'worker not found' "${LOG}"; then
        ok "${sh}: _tpm_ensure_recovery_key runs the PTY worker"
    else
        fail "${sh}: the PTY worker was not run: $(tr '\n' ';' < "${LOG}")"
    fi
done
export STUB_WORKER_RC=0

# ── N17: interrupt cleanup ───────────────────────────────────────────────────

for sh in ${SHELLS}; do
    # The guard itself: cleanup, the caller's trap restored and run, re-raised.
    out="$(in_shell "${sh}" "
trap 'echo user-trap' INT
mkdir -p '${WORK}/g-${sh}'
_TPM_CLEAN_DIR='${WORK}/g-${sh}'
_tpm_trap_guard
kill -s INT \$\$
trap > '${WORK}/traps-${sh}'
")"
    if [[ ! -e "${WORK}/g-${sh}" && "${out}" == *user-trap* ]] && grep -q "user-trap" "${WORK}/traps-${sh}"; then
        ok "${sh}: on INT the guard removes the files, restores the caller's trap and re-raises to it"
    else
        fail "${sh}: guard on INT: dir left: $([[ -e "${WORK}/g-${sh}" ]] && echo yes || echo no), output '${out}', traps: $(tr '\n' ';' < "${WORK}/traps-${sh}" 2>/dev/null)"
    fi
    out="$(in_shell "${sh}" "
trap 'echo user-trap' INT
_tpm_trap_guard
_tpm_trap_release
trap > '${WORK}/traps-${sh}'
")"
    if grep -q "user-trap" "${WORK}/traps-${sh}" && ! grep -q '_tpm_on_signal' "${WORK}/traps-${sh}"; then
        ok "${sh}: _tpm_trap_release puts back the caller's trap"
    else
        fail "${sh}: after release, traps are: $(tr '\n' ';' < "${WORK}/traps-${sh}")"
    fi

    # Recovery-key transcript: INT while the worker runs.
    STUB_INTERRUPT=1 in_shell "${sh}" '_tpm_ensure_recovery_key /dev/fake; echo after' >/dev/null
    rc=$?
    transcript="$(sed -n 's/^transcript //p' "${LOG}" | head -1)"
    if [[ -n "${transcript}" && ! -e "${transcript}" && ${rc} -ne 0 ]]; then
        ok "${sh}: INT during recovery-key capture removes the transcript and stops"
    else
        fail "${sh}: transcript '${transcript}' left: $([[ -e "${transcript}" ]] && echo yes || echo no), rc=${rc}"
        [[ -n "${transcript}" ]] && rm -f "${transcript}"
    fi

    # 1Password item file: INT during `op item create`.
    STUB_INTERRUPT=1 in_shell "${sh}" '_tpm_op_store_recovery title SENTINEL; echo after' >/dev/null
    rc=$?
    op_dir="$(sed -n 's/^op-dir //p' "${LOG}" | head -1)"
    if [[ -n "${op_dir}" && ! -e "${op_dir}" && ${rc} -ne 0 ]]; then
        ok "${sh}: INT during op item create removes the item file's directory and stops"
    else
        fail "${sh}: op dir '${op_dir}' left: $([[ -e "${op_dir}" ]] && echo yes || echo no), rc=${rc}"
    fi
done

# ── TPM2+PIN is not replaced silently ────────────────────────────────────────

PIN_JSON='{"keyslots":{},"tokens":{"0":{"type":"systemd-tpm2","keyslots":["2"],"tpm2-pin":true}}}'
NOPIN_JSON='{"keyslots":{},"tokens":{"0":{"type":"systemd-tpm2","keyslots":["2"],"tpm2-pin":false}}}'
# shellcheck disable=SC2016  # expands in the child shell, not here
ENROLL='_tpm_ensure_recovery_key() { echo "ensure-recovery" >> "${LOG}"; }
_tpm_show_slots() { :; }'

# pin_case <label> <with_pin> <json|""> <tty yes|no> <answer> <expect enrolled|refused>
pin_case() {
    local label="$1" with_pin="$2" json="$3" tty="$4" answer="$5" expect="$6" sh rc
    for sh in ${SHELLS}; do
        STUB_TOKENS="password recovery tpm2" STUB_JSON="${json}" STUB_ANSWER="${answer}" \
            in_shell "${sh}" "${ENROLL}
_tpm_have_tty() { [[ '${tty}' == yes ]]; }
_tpm_enroll_device /dev/fake ${with_pin}" >/dev/null
        rc=$?
        if [[ "${expect}" == "refused" ]]; then
            if [[ ${rc} -ne 0 ]] && ! grep -q 'tpm2-device=auto' "${LOG}" && ! grep -q 'ensure-recovery' "${LOG}"; then
                ok "${sh}: ${label}: refused, nothing changed"
            else
                fail "${sh}: ${label}: expected refusal (rc=${rc}): $(tr '\n' ';' < "${LOG}")"
            fi
        else
            if [[ ${rc} -eq 0 ]] && grep -q 'systemd-cryptenroll --wipe-slot=tpm2' "${LOG}"; then
                ok "${sh}: ${label}: enrolled"
            else
                fail "${sh}: ${label}: expected enrollment (rc=${rc}): $(tr '\n' ';' < "${LOG}")"
            fi
        fi
    done
}

pin_case "PIN token, no --with-pin, no terminal"          false "${PIN_JSON}"   no  ""  refused
pin_case "PIN token, no --with-pin, answer no"            false "${PIN_JSON}"   yes n   refused
pin_case "PIN token, no --with-pin, answer yes"           false "${PIN_JSON}"   yes y   enrolled
pin_case "PIN token, --with-pin"                          true  "${PIN_JSON}"   no  ""  enrolled
pin_case "TPM2-only token, no --with-pin"                 false "${NOPIN_JSON}" no  ""  enrolled
pin_case "unreadable header, no --with-pin, no terminal"  false ""              no  ""  refused

STUB_TOKENS="password recovery tpm2" STUB_JSON="${PIN_JSON}" STUB_ANSWER="n" \
    in_shell bash "${ENROLL}
_tpm_have_tty() { return 0; }
_tpm_enroll_device /dev/fake false" >/dev/null
if grep -qF 'asked:   This replaces your TPM2+PIN unlock with TPM2-only. Continue? [y/N]: ' "${LOG}"; then
    ok "the question names what is replaced"
else
    fail "the PIN question was not asked as expected: $(tr '\n' ';' < "${LOG}")"
fi

# ── rotate-luks-key --with-pin ───────────────────────────────────────────────

# shellcheck disable=SC2016  # expands in the child shell, not here
ROTATE='_tpm_require_tools() { :; }
_tpm_find_luks_devices() { echo /dev/fake; }
_tpm_ensure_recovery_key() { :; }
_tpm_check_tpm2_device() { :; }
_tpm_has_token_type() { return 1; }
_tpm_enroll_device() { echo "enroll $*" >> "${LOG}"; }'
for sh in ${SHELLS}; do
    STUB_ANSWER=y in_shell "${sh}" "${ROTATE}
rotate-luks-key --with-pin" >/dev/null
    if grep -qx 'enroll /dev/fake true' "${LOG}"; then ok "${sh}: rotate-luks-key --with-pin enrolls with a PIN"; else fail "${sh}: rotate-luks-key --with-pin: $(tr '\n' ';' < "${LOG}")"; fi
    STUB_ANSWER=y in_shell "${sh}" "${ROTATE}
rotate-luks-key" >/dev/null
    if grep -qx 'enroll /dev/fake false' "${LOG}"; then ok "${sh}: rotate-luks-key without --with-pin enrolls TPM2-only"; else fail "${sh}: rotate-luks-key: $(tr '\n' ';' < "${LOG}")"; fi
    in_shell "${sh}" "${ROTATE}
rotate-luks-key --bogus" >/dev/null
    rc=$?
    if [[ ${rc} -eq 2 ]] && ! grep -q '^enroll' "${LOG}"; then ok "${sh}: rotate-luks-key rejects an unknown option"; else fail "${sh}: rotate-luks-key --bogus gave rc=${rc}"; fi
done

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
