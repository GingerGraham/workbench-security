#!/usr/bin/env bash
# tests/check-cd-wrapper.sh — workbench-core docs/decisions-log.md D110
# acceptance check, adapted for this module.
#
# Behavioural half of tests/check-no-bare-cd.sh. Builds a shell the way a
# host with its own profile builds one — `ls`, `cat`, `cp`, `mv` and `find`
# aliased to something noisy, `cd` both aliased and wrapped by a function —
# and then sources each of this module's shell files. None of the host
# wrappers may run while a file is sourced, and none may be baked into a
# function the file defines.
#
# An alias is expanded when a line is read, and a function body is read when
# the function is defined. So the wrappers are defined on lines of their own
# BEFORE anything is sourced, and a bare `cd` inside a function shows up as
# the alias text in that function's `declare -f` body even if the function is
# never called. Aliases are switched on explicitly for the non-interactive
# shell that runs the fixture.
#
# The module's shell files expect functions that workbench-core provides
# (log_info, _wb_alias_availability, ...). Those are absent here; the errors
# that follow are not what this checks.
#
# Bash 3.2 compatible.
set -uo pipefail

SCRIPT_DIR="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(builtin cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
export XDG_DATA_HOME="${WORK}/data"
export XDG_CONFIG_HOME="${WORK}/config"
export XDG_CACHE_HOME="${WORK}/cache"
mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"
: > "${HOME}/.bashrc"

# The host's wrappers. Written to a file that each fixture shell sources
# first. The function comes before the aliases: once the `cd` alias exists,
# the line `cd() {` would itself be alias-expanded and fail to parse.
#
# rm is not aliased: this module deliberately keeps `rm -f` / `rm -rf`
# bare, because a force flag overrides an interactive alias. WORKBENCH_OS is
# set because shell/disk-encryption.sh returns early on anything but Linux.
cat > "${WORK}/host-wrappers.sh" <<'WRAPPERS_EOF'
shopt -s expand_aliases
cd() { printf 'WRAPPER-CALLED\n' >&2; return 1; }
alias ls='printf "ALIAS-LS-RAN\n"; ls -1 --'
alias cd='printf "ALIAS-CD-RAN\n" >&2; false; :'
alias cat='printf "ALIAS-CAT-RAN\n" >&2; command cat'
alias cp='printf "ALIAS-CP-RAN\n" >&2; command cp -i'
alias mv='printf "ALIAS-MV-RAN\n" >&2; command mv -i'
alias find='printf "ALIAS-FIND-RAN\n" >&2; command find'
WRAPPERS_EOF

# Stand-ins for the CLIs this module's files guard on with `command -v`.
# Without them a file returns early on this host and defines nothing, and
# the function-body check below would look at nothing.
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
for tool in clamscan sonar-scanner nc cryptsetup blkid systemd-cryptenroll systemctl python3 op bw; do
    printf '#!/bin/sh\nexit 0\n' > "${STUBS}/${tool}"
    chmod +x "${STUBS}/${tool}"
done

MARKERS_RE='ALIAS-LS-RAN|ALIAS-CD-RAN|ALIAS-CAT-RAN|ALIAS-CP-RAN|ALIAS-MV-RAN|ALIAS-FIND-RAN|WRAPPER-CALLED'

# run_fixture <script-body> — run <script-body> in a clean bash that has the
# host wrappers installed first. Prints stdout and stderr together.
run_fixture() {
    local body="$1"
    env -i \
        HOME="${HOME}" \
        XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        WORKBENCH_OS=Linux \
        PATH="${STUBS}:${PATH}" \
        bash -c ". '${WORK}/host-wrappers.sh'
${body}" 2>&1
}

assert_no_markers() {
    local label="$1" output="$2"
    if printf '%s\n' "${output}" | grep -Eq "${MARKERS_RE}"; then
        fail "${label}: a host alias or wrapper ran or was baked into a function:"
        printf '%s\n' "${output}" | grep -E "${MARKERS_RE}" | sort | uniq -c
    else
        ok "${label}: no host alias or wrapper ran, none baked into a function body"
    fi
}

# source_and_dump <file> — source <file> under the host wrappers, then print
# the body of every function it defined (`declare -f`), so a baked-in alias
# is visible. Function names are collected with compgen, which Bash 3.2 has.
source_and_dump() {
    local file="$1"
    run_fixture "set --
_before=\" \$(compgen -A function | tr '\\n' ' ') \"
. '${file}'
for _fn in \$(compgen -A function); do
    case \"\${_before}\" in *\" \${_fn} \"*) continue ;; esac
    echo \"DEFINED=\${_fn}\"
    declare -f \"\${_fn}\"
done"
}

# ── Every shell file this module ships. ────────────────────────────────────
for file in "${REPO_ROOT}"/shell/*.sh "${REPO_ROOT}"/shell/completions/*.sh; do
    [[ -f "${file}" ]] || continue
    rel="${file#"${REPO_ROOT}"/}"
    OUT="$(source_and_dump "${file}")"
    assert_no_markers "sourcing ${rel}" "${OUT}"
    # A file that defines functions must have defined some here, or the
    # check above looked at nothing.
    n_defined="$(printf '%s\n' "${OUT}" | grep -c '^DEFINED=')"
    if grep -Eq '^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)' "${file}"; then
        if [[ "${n_defined}" -gt 0 ]]; then
            ok "${rel}: ${n_defined} function(s) defined and inspected"
        else
            fail "${rel}: defines functions but none were defined under the fixture, so the body check saw nothing"
        fi
    fi
done

# ── shell/disk-encryption.sh resolves the module root at source time. ─────
# It does this with `cd` in a command substitution, and later uses the path
# to find workers/disk-encryption-pty-capture.py. A host cd wrapper that
# fails would leave it empty or wrong.
OUT="$(run_fixture "set --
. '${REPO_ROOT}/shell/disk-encryption.sh' >/dev/null 2>&1
echo \"DIR=\${_de_module_dir:-unset}\"")"
assert_no_markers "shell/disk-encryption.sh path resolution" "${OUT}"
resolved="$(printf '%s\n' "${OUT}" | grep '^DIR=' | sed 's/^DIR=//')"
if [[ "${resolved}" == "${REPO_ROOT}" ]]; then
    ok "shell/disk-encryption.sh resolved the module root (_de_module_dir)"
else
    fail "shell/disk-encryption.sh: _de_module_dir is '${resolved}', expected '${REPO_ROOT}'"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
else
    echo "${FAILED} of ${check_no} checks failed."
    exit 1
fi
