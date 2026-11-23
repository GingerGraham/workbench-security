#!/usr/bin/env bash
# tests/check-macos-secret-tool.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework).
#
# Covers shell/macos.sh, the Keychain-backed `secret-tool` for macOS:
#   - store/lookup/clear behave like libsecret's secret-tool (exit codes,
#     no trailing newline, replace-on-store, silent miss);
#   - the secret never appears in the argument list of any command;
#   - what the Keychain can't represent is refused up front, before any
#     `security` command runs;
#   - a `security -i` that fails without saying so is caught by the read-back;
#   - the file defines nothing off macOS;
#   - the existing sonar-token-* helpers work on top of it.
#
# `security` is a stub (a directory of items, one file each) so this runs on
# Linux and in macOS CI without touching a Keychain. The stub encodes what
# the real command is believed to do: `security -i` takes commands on stdin,
# `-X` takes hex, `find-generic-password -w` prints the password plus a
# newline, and a missing item exits 44. The real command is not exercised
# here; see the macOS check in the pull request.
#
# Runs under bash and, when installed, zsh.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

SECRET="SENTINEL-keychain-secret-0123" # gitleaks:allow (placeholder the stub round-trips)
SECRET_HEX="$(printf '%s' "${SECRET}" | od -An -v -tx1 | tr -d ' \n')"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
export KC_DIR="${WORK}/keychain"
export ARGV_LOG="${WORK}/argv"
mkdir -p "${STUBS}" "${KC_DIR}"

# ── The fake `security` ──────────────────────────────────────────────────────

cat > "${STUBS}/security" <<'STUB'
#!/usr/bin/env bash
# Records its own argument list, one line per call.
{ printf 'security'; printf ' %s' "$@"; printf '\n'; } >> "${ARGV_LOG}"

item_file() { printf '%s/%s@@%s' "${KC_DIR}" "$1" "$2"; }

# hex string -> raw bytes in a file
write_hex() {
    local hex="$1" file="$2" i
    : > "${file}"
    for ((i = 0; i < ${#hex}; i += 2)); do
        printf "\\x${hex:i:2}" >> "${file}"
    done
}

run_command() {
    local cmd="$1" account="" service="" hex="" want_password=0
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a) account="$2"; shift 2 ;;
            -s) service="$2"; shift 2 ;;
            -X) hex="$2"; shift 2 ;;
            -l) shift 2 ;;
            -w) want_password=1; shift ;;
            *) shift ;;
        esac
    done
    local file
    file="$(item_file "${account}" "${service}")"
    case "${cmd}" in
        add-generic-password)
            # STUB_IGNORE_ADD=1: succeed without storing, as a failing
            # `security -i` command would look from outside.
            [[ "${STUB_IGNORE_ADD:-0}" == "1" ]] || write_hex "${hex}" "${file}"
            ;;
        find-generic-password)
            if [[ ! -f "${file}" ]]; then
                echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
                return 44
            fi
            [[ "${want_password}" -eq 1 ]] && { cat "${file}"; printf '\n'; }
            ;;
        delete-generic-password)
            if [[ ! -f "${file}" ]]; then
                echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
                return 44
            fi
            rm -f "${file}"
            ;;
        *) echo "stub security: unknown command ${cmd}" >&2; return 1 ;;
    esac
}

if [[ "${1:-}" == "-i" ]]; then
    # Commands on stdin, one per line, shell-style quoting.
    while IFS= read -r line; do
        printf '%s\n' "${line}" >> "${ARGV_LOG}.stdin"
        eval "set -- ${line}"
        run_command "$@"
    done
    exit 0
fi
run_command "$@"
STUB
chmod +x "${STUBS}/security"
export PATH="${STUBS}:${PATH}"

# ── Source the file with core stubs ──────────────────────────────────────────

# shellcheck disable=SC2329  # called by the sourced file
log_error() { echo "[ERROR] $*" >&2; }

# Off macOS the file must define nothing.
if WORKBENCH_OS=Linux bash -c 'source "$1"; declare -F secret-tool >/dev/null' _ "${REPO_ROOT}/shell/macos.sh"; then
    fail "on Linux, shell/macos.sh defined secret-tool"
else
    ok "on Linux, shell/macos.sh defines no secret-tool"
fi

export WORKBENCH_OS=Mac
# shellcheck disable=SC1091
source "${REPO_ROOT}/shell/macos.sh"

# Runs a command and keeps its stdout exactly, trailing newlines included.
# Sets OUT (stdout), ERR (stderr) and RC.
capture() {
    local out_file="${WORK}/out" err_file="${WORK}/err"
    "$@" >"${out_file}" 2>"${err_file}"
    RC=$?
    OUT="$(cat "${out_file}"; printf x)"; OUT="${OUT%x}"
    ERR="$(cat "${err_file}"; printf x)"; ERR="${ERR%x}"
}

reset_log() { : > "${ARGV_LOG}"; : > "${ARGV_LOG}.stdin"; }
calls() { grep -c '^security' "${ARGV_LOG}" 2>/dev/null; }

# ── store / lookup / clear ───────────────────────────────────────────────────

reset_log
printf '%s' "${SECRET}" | secret-tool store --label="Test item" service wb-test account tester
rc=$?
[[ ${rc} -eq 0 ]] && ok "store reads the secret from stdin and succeeds" || fail "store returned ${rc}"

if ! grep -q '^security -i$' "${ARGV_LOG}"; then
    fail "store did not go through 'security -i' (argument log: $(cat "${ARGV_LOG}"))"
elif grep -qF "${SECRET}" "${ARGV_LOG}" || grep -qF "${SECRET_HEX}" "${ARGV_LOG}"; then
    fail "the secret (or its hex) appeared in a command's arguments: $(cat "${ARGV_LOG}")"
else
    ok "the secret is not in any command's arguments"
fi

[[ "$(cat "${KC_DIR}/tester@@wb-test" 2>/dev/null)" == "${SECRET}" ]] \
    && ok "the Keychain item holds exactly the secret" \
    || fail "the Keychain item holds '$(cat "${KC_DIR}/tester@@wb-test" 2>/dev/null)'"

grep -qF -- '-l "Test item"' "${ARGV_LOG}.stdin" \
    && ok "--label becomes the item's label" \
    || fail "label not passed: $(cat "${ARGV_LOG}.stdin")"

capture secret-tool lookup service wb-test account tester
[[ ${RC} -eq 0 && "${OUT}" == "${SECRET}" ]] \
    && ok "lookup prints the secret with no trailing newline" \
    || fail "lookup: rc=${RC}, stdout='${OUT}'"

printf '%s' "second-secret" | secret-tool store --label="Test item" service wb-test account tester
capture secret-tool lookup service wb-test account tester
[[ "${OUT}" == "second-secret" ]] \
    && ok "storing again replaces the secret" \
    || fail "after a second store, lookup gave '${OUT}'"

printf 'from-echo\n' | secret-tool store service wb-test account echoed
capture secret-tool lookup service wb-test account echoed
[[ ${RC} -eq 0 && "${OUT%$'\n'}" == "from-echo" ]] \
    && ok "a secret piped in with a trailing newline round-trips, and the label defaults" \
    || fail "echo-style store: rc=${RC}, stdout='${OUT}'"

printf 'line one\nline two' | secret-tool store service wb-test account multiline
capture secret-tool lookup service wb-test account multiline
[[ ${RC} -eq 0 && "${OUT}" == $'line one\nline two' ]] \
    && ok "a multi-line secret keeps its newline" \
    || fail "multi-line store: rc=${RC}, stdout='${OUT}'"

capture secret-tool lookup service wb-test account nobody
[[ ${RC} -eq 1 && -z "${OUT}" && -z "${ERR}" ]] \
    && ok "lookup of a missing item exits 1 and prints nothing" \
    || fail "missing lookup: rc=${RC}, stdout='${OUT}', stderr='${ERR}'"

capture secret-tool clear service wb-test account tester
[[ ${RC} -eq 0 && ! -f "${KC_DIR}/tester@@wb-test" ]] \
    && ok "clear removes the item" \
    || fail "clear: rc=${RC}, item still there: $(ls "${KC_DIR}")"

capture secret-tool lookup service wb-test account tester
[[ ${RC} -eq 1 && -z "${OUT}" ]] \
    && ok "lookup after clear finds nothing" \
    || fail "lookup after clear: rc=${RC}, stdout='${OUT}'"

capture secret-tool clear service wb-test account tester
[[ ${RC} -eq 0 && -z "${ERR}" ]] \
    && ok "clear of a missing item succeeds quietly" \
    || fail "second clear: rc=${RC}, stderr='${ERR}'"

# ── Things the Keychain can't represent: refused before any security call ────

reset_log
capture secret-tool store --label=x service wb-test colour blue </dev/null
[[ ${RC} -eq 1 && "${ERR}" == *"'colour' is not supported"* && "$(calls)" -eq 0 ]] \
    && ok "an unsupported attribute is refused before running security" \
    || fail "unsupported attribute: rc=${RC}, stderr='${ERR}', calls=$(calls)"

capture secret-tool lookup service wb-test
[[ ${RC} -eq 1 && "${ERR}" == *"both"* && "$(calls)" -eq 0 ]] \
    && ok "an item with no account is refused" \
    || fail "missing account: rc=${RC}, stderr='${ERR}', calls=$(calls)"

capture secret-tool lookup service wb-test account
[[ ${RC} -eq 1 && "${ERR}" == *"has no value"* && "$(calls)" -eq 0 ]] \
    && ok "an attribute with no value is refused" \
    || fail "dangling attribute: rc=${RC}, stderr='${ERR}', calls=$(calls)"

capture secret-tool lookup service 'wb"test' account tester
[[ ${RC} -eq 1 && "${ERR}" == *"double quote"* && "$(calls)" -eq 0 ]] \
    && ok "a double quote in a value is refused" \
    || fail "quote in value: rc=${RC}, stderr='${ERR}', calls=$(calls)"

capture secret-tool lookup service 'wb\test' account tester
[[ ${RC} -eq 1 && "$(calls)" -eq 0 ]] \
    && ok "a backslash in a value is refused" \
    || fail "backslash in value: rc=${RC}, calls=$(calls)"

capture secret-tool store --collection=default service wb-test account tester </dev/null
[[ ${RC} -eq 1 && "${ERR}" == *"--collection"* && "$(calls)" -eq 0 ]] \
    && ok "an unsupported option is refused" \
    || fail "unsupported option: rc=${RC}, stderr='${ERR}', calls=$(calls)"

capture secret-tool store --label=x service wb-test account empty </dev/null
[[ ${RC} -eq 1 && "${ERR}" == *"no secret"* && ! -f "${KC_DIR}/empty@@wb-test" ]] \
    && ok "an empty secret stores nothing" \
    || fail "empty secret: rc=${RC}, stderr='${ERR}'"

capture secret-tool search service wb-test
[[ ${RC} -eq 1 && "${ERR}" == *"not supported"* ]] \
    && ok "search is refused" \
    || fail "search: rc=${RC}, stderr='${ERR}'"

capture secret-tool
[[ ${RC} -eq 1 && "${ERR}" == *"Usage: secret-tool"* ]] \
    && ok "no action prints usage and fails" \
    || fail "no action: rc=${RC}, stderr='${ERR}'"

# ── A store that security silently drops is caught by the read-back ──────────

printf '%s' "${SECRET}" | STUB_IGNORE_ADD=1 secret-tool store service wb-test account dropped 2>"${WORK}/err"
rc=$?
[[ ${rc} -eq 1 ]] && grep -q "could not confirm" "${WORK}/err" \
    && ok "a store that didn't reach the Keychain fails" \
    || fail "dropped store: rc=${rc}, stderr='$(cat "${WORK}/err")'"

printf '%s' "new-value" | secret-tool store service wb-test account stale
printf '%s' "other-value" | STUB_IGNORE_ADD=1 secret-tool store service wb-test account stale 2>/dev/null
rc=$?
[[ ${rc} -eq 1 ]] \
    && ok "a store that left the old value in place fails" \
    || fail "stale store returned ${rc}"

# ── The existing sonar-token helpers on top of it ────────────────────────────

# shellcheck disable=SC2329  # called by the sourced file
_wb_declare_availability() { :; }
# shellcheck disable=SC2329
workbench_alias_define() { :; }
# shellcheck disable=SC1091
source "${REPO_ROOT}/shell/security.sh"

printf '%s\n' "${SECRET}" | sonar-token-set 2>/dev/null
rc=$?
capture sonar-token-get
[[ ${rc} -eq 0 && "${OUT}" == "${SECRET}" ]] \
    && ok "sonar-token-set then sonar-token-get round-trips through the Keychain" \
    || fail "sonar token: set rc=${rc}, get rc=${RC}, stdout='${OUT}'"

[[ -f "${KC_DIR}/scanner@@sonarqube" ]] \
    && ok "the token is stored under service sonarqube, account scanner" \
    || fail "no Keychain item for sonarqube/scanner: $(ls "${KC_DIR}")"

sonar-token-clear
capture sonar-token-get
[[ ${RC} -eq 1 && ! -f "${KC_DIR}/scanner@@sonarqube" ]] \
    && ok "sonar-token-clear removes it" \
    || fail "after sonar-token-clear: rc=${RC}, items: $(ls "${KC_DIR}")"

# ── zsh: the same file, sourced the way the loader does ─────────────────────

if command -v zsh &>/dev/null; then
    zsh_out="$(zsh -c '
        log_error() { echo "[ERROR] $*" >&2; }
        export WORKBENCH_OS=Mac
        source "$1"
        printf "%s" "zsh-secret" | secret-tool store --label="zsh item" service wb-test account zshuser || exit 1
        secret-tool lookup service wb-test account zshuser || exit 2
        secret-tool clear service wb-test account zshuser || exit 3
        secret-tool lookup service wb-test account zshuser && exit 4
        exit 0
    ' zsh "${REPO_ROOT}/shell/macos.sh" 2>&1)"
    rc=$?
    [[ ${rc} -eq 0 && "${zsh_out}" == "zsh-secret" ]] \
        && ok "store, lookup and clear work under zsh" \
        || fail "zsh round trip: rc=${rc}, output='${zsh_out}'"
else
    ok "zsh not installed — skipped the zsh round trip"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
