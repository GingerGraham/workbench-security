#!/usr/bin/env bash
# tests/check-manifest-structure.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching workbench-core's
# tests/check-*.sh convention (no framework). Structural checks only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# Manifest discovery, duplicated inline rather than sourced from
# workbench-core — this script runs standalone in this module's own CI,
# the same "must work without workbench-core installed alongside it"
# constraint lib/manifest/validate.sh's own header documents for its
# identical duplication (workbench-core ARCHITECTURE.md §12 D46). Checked
# in precedence order; .dotfiles-sync.yml is accepted unconditionally,
# the four new names only if they declare a top-level version: key.
_MANIFEST_CANDIDATES="workbench.yml workbench.yaml wb.yml wb.yaml .dotfiles-sync.yml"
MANIFEST=""
for _name in ${_MANIFEST_CANDIDATES}; do
    _candidate="${REPO_ROOT}/${_name}"
    [[ -f "${_candidate}" ]] || continue
    if [[ "${_name}" == ".dotfiles-sync.yml" ]]; then
        MANIFEST="${_candidate}"
        break
    fi
    grep -q '^version:' "${_candidate}" && { MANIFEST="${_candidate}"; break; }
done

if [[ -n "${MANIFEST}" ]]; then
    ok "manifest found ($(basename "${MANIFEST}"))"
else
    fail "no manifest found (checked ${_MANIFEST_CANDIDATES})"
fi

for key in version core_api register; do
    if [[ -n "${MANIFEST}" ]] && grep -q "^${key}:" "${MANIFEST}"; then
        ok "manifest declares '${key}:'"
    else
        fail "manifest missing '${key}:'"
    fi
done

if [[ -n "${MANIFEST}" ]]; then
    while IFS= read -r src; do
        [[ -z "${src}" ]] && continue
        if [[ -f "${REPO_ROOT}/${src}" ]]; then
            ok "referenced file exists: ${src}"
        else
            fail "manifest references missing file: ${src}"
        fi
    done < <(grep -E '^[[:space:]]*(-[[:space:]]*)?src:' "${MANIFEST}" | sed -E 's/^[[:space:]]*-?[[:space:]]*src:[[:space:]]*//')
fi

[[ -f "${REPO_ROOT}/workers/disk-encryption-pty-capture.py" ]] \
    && ok "workers/disk-encryption-pty-capture.py exists" \
    || fail "workers/disk-encryption-pty-capture.py missing"

if command -v python3 &>/dev/null; then
    python3 -c "import ast; ast.parse(open('${REPO_ROOT}/workers/disk-encryption-pty-capture.py').read())" \
        && ok "disk-encryption-pty-capture.py parses as valid Python" \
        || fail "disk-encryption-pty-capture.py has a syntax error"
else
    ok "python3 not available in this environment — skipped syntax check"
fi

declare -a _bash32_patterns=(
    "declare -A (associative arrays, bash 4+)|declare[[:space:]]+-A"
    "mapfile/readarray (bash 4+)|(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|\$)"
    "shopt -s globstar (bash 4+)|shopt[[:space:]]+-s[[:space:]]+globstar"
    "\${var,,} / \${var^^} case conversion (bash 4+)|\\\$\\{[a-zA-Z_][a-zA-Z0-9_]*(,,|\\^\\^)"
    "declare -n nameref (bash 4.3+)|declare[[:space:]]+-n"
)
for entry in "${_bash32_patterns[@]}"; do
    desc="${entry%%|*}"
    pattern="${entry#*|}"
    hit=""
    while IFS= read -r -d '' f; do
        grep -vE '^[[:space:]]*#' "${f}" | grep -qE "${pattern}" && hit="${hit}${f}\n"
    done < <(find "${REPO_ROOT}/shell" -type f -print0 2>/dev/null)
    if [[ -n "${hit}" ]]; then
        fail "found ${desc} in: $(printf '%b' "${hit}" | tr '\n' ' ')"
    else
        ok "no ${desc}"
    fi
done

# grep -P is a GNU-only extension -- catch it creeping back in (excluding
# comment lines, which may legitimately discuss it).
_grep_p_hit=""
while IFS= read -r -d '' f; do
    grep -vE '^[[:space:]]*#' "${f}" | grep -qE 'grep[[:space:]]+.*-[a-zA-Z]*P' && _grep_p_hit="${_grep_p_hit}${f}\n"
done < <(find "${REPO_ROOT}/shell" -type f -print0 2>/dev/null)
if [[ -n "${_grep_p_hit}" ]]; then
    fail "found grep -P (GNU-only PCRE) usage in: $(printf '%b' "${_grep_p_hit}" | tr '\n' ' ')"
else
    ok "no grep -P (GNU-only PCRE) usage in shell/"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
