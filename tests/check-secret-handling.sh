#!/usr/bin/env bash
# tests/check-secret-handling.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Verifies that secrets (the LUKS
# recovery key, the SonarQube token) never reach a child process's argv
# (security review M5) and that the transient 1Password template file lives
# in a private 0700 directory that is removed afterwards (M6). Uses stub
# bw/op/sonar-scanner/secret-tool executables that record their argv and
# stdin, so no vault or scanner is needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

SECRET="SENTINEL-recovery-key-0123456789"
TOKEN="SENTINEL-sonar-token-abcdef"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
LOG="${WORK}/log"
mkdir -p "${STUBS}" "${LOG}"

# ── Static checks ────────────────────────────────────────────────────────────

if grep -nE 'notesPlain=|-Dsonar\.token' "${REPO_ROOT}"/shell/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >/dev/null; then
    fail "shell/ still passes a secret on a command line (notesPlain= or -Dsonar.token)"
else
    ok "no notesPlain=<secret> or -Dsonar.token=<token> argument in shell/"
fi

if grep -nE 'bw create item "|bw create item \$' "${REPO_ROOT}/shell/disk-encryption.sh" >/dev/null; then
    fail "bw create item is given the encoded item as an argument"
else
    ok "bw create item takes its item on stdin"
fi

if grep -nE 'mktemp\)?[[:space:]]*$|tmp_json' "${REPO_ROOT}/shell/disk-encryption.sh" >/dev/null; then
    fail "disk-encryption.sh still writes a secret to a bare mktemp file"
else
    ok "no bare mktemp secret file in disk-encryption.sh"
fi

# ── Stubs ────────────────────────────────────────────────────────────────────

# Records "$@" (one arg per line) and stdin; passes stdin through for
# `bw encode`; `op item template get` returns a minimal template.
cat > "${STUBS}/bw" <<STUB
#!/usr/bin/env bash
{ echo "bw"; printf '%s\n' "\$@"; } >> "${LOG}/argv"
in="\$(cat)"
printf '%s' "\${in}" >> "${LOG}/bw-stdin"
[[ "\$1" == "encode" ]] && printf '%s' "\${in}"
exit 0
STUB
cat > "${STUBS}/op" <<STUB
#!/usr/bin/env bash
{ echo "op"; printf '%s\n' "\$@"; } >> "${LOG}/argv"
if [[ "\$1 \$2 \$3" == "item template get" ]]; then
    echo '{"title":"","category":"SECURE_NOTE","fields":[{"id":"notesPlain","type":"STRING","value":""}]}'
    exit 0
fi
if [[ "\$1 \$2" == "item create" ]]; then
    shift 2
    while [[ \$# -gt 0 ]]; do
        if [[ "\$1" == "--template" ]]; then
            cp "\$2" "${LOG}/op-template"
            stat -c '%a' "\$(dirname "\$2")" > "${LOG}/op-dir-mode"
            dirname "\$2" > "${LOG}/op-dir"
        fi
        shift
    done
fi
exit 0
STUB
cat > "${STUBS}/secret-tool" <<STUB
#!/usr/bin/env bash
printf '%s' "${TOKEN}"
STUB
cat > "${STUBS}/sonar-scanner" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${LOG}/sonar-argv"
printf '%s' "\${SONAR_TOKEN:-}" > "${LOG}/sonar-env"
STUB
chmod +x "${STUBS}"/*

# ── Source the module files with core stubs ──────────────────────────────────

log_info()  { :; }
log_error() { :; }
log_warn()  { :; }
_wb_alias_availability() { :; }
export WORKBENCH_OS="Linux"
export XDG_RUNTIME_DIR="${WORK}/run"
mkdir -p "${XDG_RUNTIME_DIR}"
export PATH="${STUBS}:${PATH}"

# shellcheck disable=SC1091
source "${REPO_ROOT}/shell/disk-encryption.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/shell/security.sh"

# ── Bitwarden ────────────────────────────────────────────────────────────────

_tpm_bw_store_recovery "wb-test-title" "${SECRET}"
rc=$?
if [[ ${rc} -eq 0 ]]; then ok "_tpm_bw_store_recovery succeeds against a stub bw"; else fail "_tpm_bw_store_recovery returned ${rc}"; fi

if grep -q "${SECRET}" "${LOG}/argv" 2>/dev/null; then
    fail "recovery key appeared in bw's argv"
else
    ok "recovery key is not in bw's argv"
fi
if grep -q "${SECRET}" "${LOG}/bw-stdin" 2>/dev/null; then
    ok "recovery key reached bw on stdin"
else
    fail "recovery key never reached bw on stdin"
fi

# ── 1Password ────────────────────────────────────────────────────────────────

_tpm_op_store_recovery "wb-test-title" "${SECRET}"
rc=$?
if [[ ${rc} -eq 0 ]]; then ok "_tpm_op_store_recovery succeeds against a stub op"; else fail "_tpm_op_store_recovery returned ${rc}"; fi

if grep -q "${SECRET}" "${LOG}/argv" 2>/dev/null; then
    fail "recovery key appeared in op's argv"
else
    ok "recovery key is not in op's argv"
fi
if grep -q "${SECRET}" "${LOG}/op-template" 2>/dev/null && grep -q 'wb-test-title' "${LOG}/op-template" 2>/dev/null; then
    ok "op --template file carried the key and title"
else
    fail "op --template file is missing the key or title"
fi
if [[ "$(cat "${LOG}/op-dir-mode" 2>/dev/null)" == "700" ]]; then
    ok "template directory was mode 0700"
else
    fail "template directory mode was '$(cat "${LOG}/op-dir-mode" 2>/dev/null)', expected 700"
fi
case "$(cat "${LOG}/op-dir" 2>/dev/null)" in
    "${XDG_RUNTIME_DIR}"/wb-tpm.*) ok "template directory was under \$XDG_RUNTIME_DIR" ;;
    *) fail "template directory was not under \$XDG_RUNTIME_DIR" ;;
esac
if [[ -d "$(cat "${LOG}/op-dir" 2>/dev/null)" ]]; then
    fail "template directory was left behind"
else
    ok "template directory was removed after op item create"
fi

# ── sq ───────────────────────────────────────────────────────────────────────

sq -Dsonar.projectKey=demo
if grep -q "${TOKEN}" "${LOG}/sonar-argv" 2>/dev/null; then
    fail "SonarQube token appeared in sonar-scanner's argv"
else
    ok "SonarQube token is not in sonar-scanner's argv"
fi
if [[ "$(cat "${LOG}/sonar-env" 2>/dev/null)" == "${TOKEN}" ]]; then
    ok "sonar-scanner received the token as SONAR_TOKEN"
else
    fail "sonar-scanner did not receive SONAR_TOKEN"
fi
if grep -qx -- '-Dsonar.projectKey=demo' "${LOG}/sonar-argv" && grep -qx -- '-X' "${LOG}/sonar-argv"; then
    ok "sq still passes -X and caller arguments through"
else
    fail "sq dropped -X or caller arguments"
fi
if [[ -z "${SONAR_TOKEN:-}" ]]; then
    ok "SONAR_TOKEN did not leak into the calling shell"
else
    fail "SONAR_TOKEN leaked into the calling shell"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
