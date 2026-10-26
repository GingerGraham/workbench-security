#!/usr/bin/env bash
# tests/check-aur-opt-in.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). AUR installs are opt-in
# (workbench-core D100, WORKBENCH_ALLOW_AUR=true): without it,
# install-1password on Arch prints the command to run and fails, and
# install-bitwarden on Arch uses the verified AppImage instead of yay. yay,
# git, makepkg, gpg and the core helpers are stubbed; nothing is installed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

# ── Static ───────────────────────────────────────────────────────────────────

if grep -n 'receive-keys' "${INSTALLERS}" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then
    fail "installers.sh still fetches a key with gpg --receive-keys (failure was ignored)"
else
    ok "no gpg --receive-keys in installers.sh"
fi

# ── Stubs ────────────────────────────────────────────────────────────────────

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}"
for c in yay git makepkg gpg curl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 0\n' "${c}" "${CALLS}" > "${STUBS}/${c}"
done
# git clone <url> <dir>: creates <dir>, as a clone would.
# shellcheck disable=SC2016  # expands in the stub, not here
printf '#!/usr/bin/env bash\necho "git $*" >> "%s"\nmkdir -p "${@: -1}"\n' "${CALLS}" > "${STUBS}/git"
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}"
export HOME="${WORK}/home"
mkdir -p "${HOME}"

# shellcheck disable=SC2329  # called by the sourced installers.sh
log_info()  { echo "INFO: $*" >> "${CALLS}"; }
# shellcheck disable=SC2329
log_warn()  { echo "WARN: $*" >> "${CALLS}"; }
# shellcheck disable=SC2329
log_error() { echo "ERROR: $*" >> "${CALLS}"; }
# shellcheck disable=SC2329
sudo-test() { return 0; }
# shellcheck disable=SC2329
get-elevation-command() { echo ""; }
# shellcheck disable=SC1090
source "${INSTALLERS}"
# shellcheck disable=SC2329  # replaces the sourced one: no network
_bitwarden_desktop_fetch_verified() { echo "fetch_verified $1 $2" >> "${CALLS}"; : > "$2"; }

export WORKBENCH_OS=Linux WORKBENCH_DISTRO=arch WORKBENCH_ARCH=x86_64 PACKAGE_MANAGER=pacman

# ── 1Password ────────────────────────────────────────────────────────────────

: > "${CALLS}"
unset WORKBENCH_ALLOW_AUR
install-1password >/dev/null 2>&1
rc=$?
if [[ ${rc} -ne 0 ]] && ! grep -qE '^(yay|git|makepkg|gpg) ' "${CALLS}"; then
    ok "install-1password on Arch without WORKBENCH_ALLOW_AUR fails and runs nothing"
else
    fail "install-1password without the opt-in: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
if grep -q '^WARN: To install it yourself, run: yay -S 1password$' "${CALLS}"; then
    ok "it prints the yay command to run"
else
    fail "no yay command printed: $(tr '\n' ';' < "${CALLS}")"
fi

mv "${STUBS}/yay" "${WORK}/yay.off"; hash -r
: > "${CALLS}"
_1password-install-arch >/dev/null 2>&1
rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'makepkg -si$' "${CALLS}" && ! grep -qE '^(git|makepkg) ' "${CALLS}"; then
    ok "without yay it prints the makepkg command and runs nothing"
else
    fail "makepkg hint: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
mv "${WORK}/yay.off" "${STUBS}/yay"

: > "${CALLS}"
WORKBENCH_ALLOW_AUR=true _1password-install-arch >/dev/null 2>&1
rc=$?
if [[ ${rc} -eq 0 ]] && grep -qx 'yay -S --noconfirm 1password' "${CALLS}"; then
    ok "with WORKBENCH_ALLOW_AUR=true it installs the AUR package with yay"
else
    fail "with the opt-in: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi

mv "${STUBS}/yay" "${WORK}/yay.off"; hash -r
printf '#!/usr/bin/env bash\necho "makepkg $*" >> "%s"\nexit 4\n' "${CALLS}" > "${STUBS}/makepkg"
: > "${CALLS}"
WORKBENCH_ALLOW_AUR=true _1password-install-arch >/dev/null 2>&1
rc=$?
if [[ ${rc} -eq 4 ]]; then
    ok "a failed makepkg build is reported as failure"
else
    fail "a failed makepkg build gave rc=${rc}"
fi
mv "${WORK}/yay.off" "${STUBS}/yay"

# ── Bitwarden ────────────────────────────────────────────────────────────────

: > "${CALLS}"
install-bitwarden >/dev/null 2>&1
rc=$?
if [[ ${rc} -eq 0 ]] && ! grep -q '^yay ' "${CALLS}" && grep -q 'fetch_verified x86_64\\.AppImage\$' "${CALLS}"; then
    ok "install-bitwarden on Arch without WORKBENCH_ALLOW_AUR uses the verified AppImage, not yay"
else
    fail "install-bitwarden without the opt-in: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
if grep -q 'yay -S bitwarden-bin' "${CALLS}"; then
    ok "it says which yay command would install the AUR package"
else
    fail "no yay -S bitwarden-bin hint: $(tr '\n' ';' < "${CALLS}")"
fi

: > "${CALLS}"
WORKBENCH_ALLOW_AUR=true install-bitwarden >/dev/null 2>&1
if grep -qx 'yay -S --noconfirm bitwarden-bin' "${CALLS}" && ! grep -q '^fetch_verified' "${CALLS}"; then
    ok "with WORKBENCH_ALLOW_AUR=true install-bitwarden uses yay"
else
    fail "install-bitwarden with the opt-in: $(tr '\n' ';' < "${CALLS}")"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
