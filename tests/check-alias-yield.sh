#!/usr/bin/env bash
# tests/check-alias-yield.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching workbench-core's
# tests/check-*.sh convention (no framework).
#
# workbench-core D124: workbench never replaces an alias or function it did
# not define. This module defines every alias through workbench_alias_define,
# so a name the user's shell already uses is left alone.
#
# Proves, with the module's real shell files, once per scenario below (a
# scenario is the set of tools on PATH, which decides which gated aliases
# exist):
#   - with nothing in the way, every alias is defined exactly as before the
#     conversion (tests/fixtures/alias-<scenario>.golden, captured from the
#     unconverted files);
# and, in the first scenario:
#   - with a function, or a different alias, already in the way, those names
#     are untouched, every other alias is defined, and each is recorded as a
#     clash of the right kind;
#   - the reported sequence: a host file defining `name() {` re-sourced after
#     the module loaded raises no syntax error.
#
# PATH is a directory of fake tools plus a short list of system utilities,
# nothing else, so the result does not depend on what is installed.
#
# The helper under test is core's own when a core checkout is found
# (WORKBENCH_CORE_DIR, or ../workbench-core next to this repo). Module CI runs
# this suite with only this repo checked out, so otherwise a small double
# stands in, written to the contract in core's contracts/core-api.md; core's
# own tests cover the real helper.
#
# Regenerate the golden files only on purpose, from the unconverted files:
#   WB_UPDATE_GOLDEN=1 MODULE_ROOT=<tree before the conversion> bash tests/check-alias-yield.sh
#
# Runs under bash and, when installed, zsh.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
set -uo pipefail

MODULE_NAME="security"
# Shell files to source, in order, relative to the module root.
SHELL_FILES=("shell/security.sh")
# Scenarios: "<name>|<fake tools on PATH>". The first one is used for the
# clash and re-source checks.
SCENARIOS=(
    "tools|clamscan freshclam nc sonar-scanner secret-tool"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE_ROOT="${MODULE_ROOT:-${REPO_ROOT}}"
FIXTURES="${SCRIPT_DIR}/fixtures"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

BASH_BIN="$(command -v bash)"
ZSH_BIN="$(command -v zsh 2>/dev/null || true)"

# ── Where does the helper come from? ────────────────────────────────────────
CORE_FUNCTIONS=""
for candidate in "${WORKBENCH_CORE_DIR:-}" "${REPO_ROOT}/../workbench-core"; do
    [[ -n "${candidate}" ]] || continue
    if [[ -f "${candidate}/lib/core/functions.sh" ]] \
        && grep -q '^workbench_alias_define()' "${candidate}/lib/core/functions.sh"; then
        CORE_FUNCTIONS="$(cd "${candidate}" && pwd)/lib/core"
        break
    fi
done

if [[ -n "${CORE_FUNCTIONS}" ]]; then
    printf '%s\n' \
        "source '${CORE_FUNCTIONS}/log.sh' >/dev/null 2>&1" \
        "source '${CORE_FUNCTIONS}/functions.sh' >/dev/null 2>&1" > "${WORK}/prelude.sh"
    HELPER_SOURCE="core's real functions.sh"
else
    cat > "${WORK}/prelude.sh" <<'PRELUDE'
log_info()  { echo "INFO $*"; }
log_warn()  { echo "WARN $*"; }
log_error() { echo "ERROR $*"; }
log_debug() { :; }
_wb_alias_availability()   { :; }
_wb_declare_availability() { :; }
_wb_availability_needs()   { :; }
_wb_prompt_hook_registered() { return 1; }
_read_prompt() { :; }
_str_lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
WORKBENCH_ALIASES_OURS="${WORKBENCH_ALIASES_OURS:-}"
WORKBENCH_ALIAS_CLASHES="${WORKBENCH_ALIAS_CLASHES:-}"
# The contract in core's contracts/core-api.md, in the same words.
workbench_alias_define() {
    local name="$1" module="$2" value="$3" kind existing wanted
    case " ${WORKBENCH_ALIASES_OURS} " in
        *" ${name} "*) builtin alias "${name}=${value}"; return 0 ;;
    esac
    if builtin typeset -f "${name}" >/dev/null 2>&1; then
        kind="function"
    elif builtin alias "${name}" >/dev/null 2>&1; then
        existing="$(builtin alias "${name}")"
        wanted="$( builtin unalias "${name}"; builtin alias "${name}=${value}"; builtin alias "${name}" )"
        if [[ "${existing}" == "${wanted}" ]]; then
            WORKBENCH_ALIASES_OURS="${WORKBENCH_ALIASES_OURS} ${name}"
            return 0
        fi
        kind="alias"
    else
        builtin alias "${name}=${value}"
        WORKBENCH_ALIASES_OURS="${WORKBENCH_ALIASES_OURS} ${name}"
        return 0
    fi
    WORKBENCH_ALIAS_CLASHES="${WORKBENCH_ALIAS_CLASHES}${name}|${module}|${kind}|${value}
"
    return 1
}
PRELUDE
    HELPER_SOURCE="a test double of the contract (no core checkout found)"
fi
echo "NOTE: alias helper under test: ${HELPER_SOURCE}"

FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"

# make_path <scenario> <tools...> — a bin directory with the system
# utilities module code calls at source time, plus the scenario's fake tools.
make_path() {
    local dir="${WORK}/bin-$1" tool real
    shift
    mkdir -p "${dir}"
    for tool in awk basename cat cksum cut date dirname env grep head id ls mkdir mktemp printf rm sed sort tail tr uname wc whoami; do
        real="$(command -v "${tool}" 2>/dev/null || true)"
        [[ "${real}" == /* && ! -e "${dir}/${tool}" ]] && ln -s "${real}" "${dir}/${tool}"
    done
    for tool in "$@"; do
        printf '#!/bin/sh\nexit 0\n' > "${dir}/${tool}"
        chmod +x "${dir}/${tool}"
    done
    printf '%s\n' "${dir}"
}

# The sourcing line for every module file, then the case body.
sources_line() {
    local f line=""
    for f in "${SHELL_FILES[@]}"; do line="${line}. '${MODULE_ROOT}/${f}' >/dev/null 2>&1; "; done
    printf '%s' "${line}"
}

# run_case <bash|zsh> <name> <path-dir> <body> — a clean shell: the prelude,
# then the body. Output is the body's own.
run_case() {
    local shell="$1" name="$2" pathdir="$3" body="$4" script
    script="${WORK}/case-${name}-${shell}.sh"
    {
        [[ "${shell}" == "bash" ]] && echo "shopt -s expand_aliases"
        echo ". '${WORK}/prelude.sh'"
        echo ". '${WORK}/dump.sh'"
        printf '%s\n' "${body}"
    } > "${script}"
    if [[ "${shell}" == "bash" ]]; then
        env -i HOME="${FAKE_HOME}" PATH="${pathdir}" TERM=dumb "${BASH_BIN}" --noprofile --norc "${script}" 2>&1 </dev/null
    else
        env -i HOME="${FAKE_HOME}" PATH="${pathdir}" TERM=dumb "${ZSH_BIN}" -f "${script}" 2>&1 </dev/null
    fi
}

# The alias dump: this shell's aliases as sorted `name=value` lines, where the
# value is the raw text, not the shell's display of it. bash and zsh quote an
# embedded single quote differently, so each shell evaluates its own quoting
# back to the value. zsh ships two aliases of its own (run-help,
# which-command), which are left out.
cat > "${WORK}/dump.sh" <<'DUMP'
__wb_alias_dump() {
    local __l __n __r __v
    alias | while IFS= read -r __l; do
        __l="${__l#alias }"
        __n="${__l%%=*}"
        __r="${__l#*=}"
        eval "__v=${__r}"
        printf '%s=%s\n' "${__n}" "${__v}"
    done | grep -vE '^(run-help|which-command)=' | sort
}
__wb_fn_state() { typeset -f | cksum; }
DUMP
ALIAS_DUMP='__wb_alias_dump'

scenario_name()  { printf '%s' "${1%%|*}"; }
scenario_tools() { printf '%s' "${1#*|}"; }

if [[ -n "${WB_UPDATE_GOLDEN:-}" ]]; then
    mkdir -p "${FIXTURES}"
    for scenario in "${SCENARIOS[@]}"; do
        sname="$(scenario_name "${scenario}")"
        # shellcheck disable=SC2046  # the tool list is meant to split
        pathdir="$(make_path "${sname}" $(scenario_tools "${scenario}"))"
        run_case bash "golden-${sname}" "${pathdir}" "$(sources_line) ${ALIAS_DUMP}" > "${FIXTURES}/alias-${sname}.golden"
        echo "Wrote ${FIXTURES}/alias-${sname}.golden ($(grep -c . "${FIXTURES}/alias-${sname}.golden") aliases) from ${MODULE_ROOT}"
    done
    exit 0
fi

# ── Per scenario: nothing in the way. ───────────────────────────────────────
check_plain() {
    local shell="$1" scenario="$2" sname pathdir golden out
    sname="$(scenario_name "${scenario}")"
    golden="${FIXTURES}/alias-${sname}.golden"
    [[ -f "${golden}" ]] || { fail "${shell}/${sname}: golden file missing: ${golden}"; return; }
    # shellcheck disable=SC2046  # the tool list is meant to split
    pathdir="$(make_path "${sname}" $(scenario_tools "${scenario}"))"
    out="$(run_case "${shell}" "plain-${sname}" "${pathdir}" "$(sources_line) ${ALIAS_DUMP}")"
    if [[ "${out}" == "$(cat "${golden}")" ]]; then
        ok "${shell}/${sname}: no foreign state — all $(grep -c . "${golden}") aliases defined, same names and values as before the conversion"
    else
        fail "${shell}/${sname}: aliases differ from the golden file (expected vs got):"
        diff <(cat "${golden}") <(printf '%s\n' "${out}") | head -20
    fi
}

# ── First scenario: names taken by the host. ────────────────────────────────
check_clash() {
    local shell="$1" scenario="$2" sname pathdir golden out expected
    local -a names=()
    local fn_a fn_b alias_c n
    sname="$(scenario_name "${scenario}")"
    golden="${FIXTURES}/alias-${sname}.golden"
    # shellcheck disable=SC2046  # the tool list is meant to split
    pathdir="$(make_path "${sname}" $(scenario_tools "${scenario}"))"
    while IFS= read -r n; do names+=("${n}"); done < <(sed 's/=.*//' "${golden}" | head -n 3)
    fn_a="${names[0]}"
    if [[ "${#names[@]}" -ge 3 ]]; then
        fn_b="${names[1]}"; alias_c="${names[2]}"
    else
        fn_b=""; alias_c="${names[1]}"
    fi

    # The host's own definitions, one per line in a sourced file.
    {
        printf '%s() {\n    echo "host %s function"\n}\n' "${fn_a}" "${fn_a}"
        [[ -n "${fn_b}" ]] && printf '%s() { echo "host %s function"; }\n' "${fn_b}" "${fn_b}"
        printf "alias %s='echo host-alias'\n" "${alias_c}"
    } > "${WORK}/host-clashes.sh"
    printf '%s() {\n    echo "host %s function"\n}\n' "${fn_a}" "${fn_a}" > "${WORK}/host-fn.sh"

    out="$(run_case "${shell}" "clash-${sname}" "${pathdir}" ". '${WORK}/host-clashes.sh'; $(sources_line) ${ALIAS_DUMP}")"
    expected="$( { grep -vE "^(${fn_a}|${fn_b:-@none@}|${alias_c})=" "${golden}"; echo "${alias_c}=echo host-alias"; } | sort )"
    if [[ "${out}" == "${expected}" ]]; then
        ok "${shell}: ${fn_a}${fn_b:+, ${fn_b}} (functions) and ${alias_c} (a different alias) are untouched; every other alias is defined"
    else
        fail "${shell}: aliases with the host's names taken are not as expected (expected vs got):"
        diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${out}") | head -20
    fi

    out="$(run_case "${shell}" "kinds-${sname}" "${pathdir}" ". '${WORK}/host-clashes.sh'; $(sources_line) printf '%s' \"\${WORKBENCH_ALIAS_CLASHES}\"")"
    local want=2 fns=1
    [[ -n "${fn_b}" ]] && { want=3; fns=2; }
    if [[ "$(grep -c . <<<"${out}")" -eq "${want}" ]] \
        && [[ "$(grep -c "^[^|]*|${MODULE_NAME}|function|" <<<"${out}")" -eq "${fns}" ]] \
        && grep -q "^${alias_c}|${MODULE_NAME}|alias|" <<<"${out}" \
        && grep -q "^${fn_a}|${MODULE_NAME}|function|" <<<"${out}"; then
        ok "${shell}: ${want} clashes recorded — ${fns} function, 1 alias, module '${MODULE_NAME}'"
    else
        fail "${shell}: clash records wrong"; printf '%s\n' "${out}"
    fi

    # FNSET: re-sourcing must leave every function as it was. In bash an alias
    # with a single-word value does not break `name() {`; it silently defines
    # (or overwrites) a different function, the alias's value, which only a
    # comparison of the definitions themselves catches.
    out="$(run_case "${shell}" "resource-${sname}" "${pathdir}" ". '${WORK}/host-fn.sh'; $(sources_line) __b=\"\$(__wb_fn_state)\"; . '${WORK}/host-fn.sh'; echo R1=\$?; . '${WORK}/host-fn.sh'; echo R2=\$?; __a=\"\$(__wb_fn_state)\"; [ \"\${__b}\" = \"\${__a}\" ] && echo FNSET=same || echo FNSET=changed; ${fn_a}")"
    if grep -q '^R1=0$' <<<"${out}" && grep -q '^R2=0$' <<<"${out}" && grep -q '^FNSET=same$' <<<"${out}" \
        && grep -q "^host ${fn_a} function\$" <<<"${out}" \
        && ! grep -qiE 'syntax error|parse error|defining function based on alias' <<<"${out}"; then
        ok "${shell}: re-sourcing the host's ${fn_a}() { file twice after the module loaded: no error, ${fn_a} is still the host's function"
    else
        fail "${shell}: re-sourcing the host's file broke"; printf '%s\n' "${out}"
    fi
}

for shell in bash zsh; do
    if [[ "${shell}" == "zsh" && -z "${ZSH_BIN}" ]]; then
        skip "zsh is not installed — zsh checks not run (CI installs zsh on ubuntu so it never skips there)"
        continue
    fi
    for scenario in "${SCENARIOS[@]}"; do
        check_plain "${shell}" "${scenario}"
    done
    check_clash "${shell}" "${SCENARIOS[0]}"
done

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks failed."
exit 1
