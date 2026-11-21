#!/usr/bin/env bash
# tests/check-sonar.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Covers install-secret-tool,
# install-sonar-scanner, install-sonar and the SonarQube token helpers
# (sonar-token-set/-get/-clear). Package managers, curl, unzip, secret-tool
# and every download are stubbed; the home directory is a temp directory. No
# network, no root, nothing installed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers.sh"
SECURITY_SH="${REPO_ROOT}/shell/security.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

TOKEN="SENTINEL-sonar-token-0123456789"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}" "${WORK}/home"
: > "${CALLS}"

# ── Static: the keyring attributes agree between the two files ───────────────

inst_service="$(sed -n 's/^_SONAR_TOKEN_SERVICE="\(.*\)"$/\1/p' "${INSTALLERS}")"
inst_account="$(sed -n 's/^_SONAR_TOKEN_ACCOUNT="\(.*\)"$/\1/p' "${INSTALLERS}")"
sec_service="$(sed -n 's/^_sonar_token_service="\(.*\)"$/\1/p' "${SECURITY_SH}")"
sec_account="$(sed -n 's/^_sonar_token_account="\(.*\)"$/\1/p' "${SECURITY_SH}")"
if [[ -n "${inst_service}" && "${inst_service}" == "${sec_service}" && -n "${inst_account}" && "${inst_account}" == "${sec_account}" ]]; then
    ok "installers.sh and security.sh store the token under the same service/account"
else
    fail "keyring attributes differ: installers '${inst_service}/${inst_account}', security '${sec_service}/${sec_account}'"
fi

# ── Stubs ────────────────────────────────────────────────────────────────────

# Every stub appends "<name> <args>" to CALLS. secret-tool also records its
# stdin and answers `lookup` from STORED_TOKEN.
for name in dnf yum apt-get zypper pacman brew; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 0\n' "${name}" "${CALLS}" > "${STUBS}/${name}"
done
cat > "${STUBS}/secret-tool" <<STUB
#!/usr/bin/env bash
echo "secret-tool \$*" >> "${CALLS}"
case "\$1" in
    store)  cat > "${WORK}/secret-stdin" ;;
    lookup) printf '%s' "\${STORED_TOKEN:-}" ;;
esac
exit 0
STUB
cat > "${STUBS}/unzip" <<STUB
#!/usr/bin/env bash
echo "unzip \$*" >> "${CALLS}"
dir="\$4"
mkdir -p "\${dir}/sonar-scanner-fake/bin" "\${dir}/sonar-scanner-fake/jre"
printf '#!/bin/sh\necho scanner\n' > "\${dir}/sonar-scanner-fake/bin/sonar-scanner"
chmod +x "\${dir}/sonar-scanner-fake/bin/sonar-scanner"
exit 0
STUB
# curl: only the Maven metadata lookup uses it; everything else is a stubbed download.
printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\ncat "%s/metadata.xml"\n' "${CALLS}" "${WORK}" > "${STUBS}/curl"
# brew: nothing is installed yet, so `brew list` fails and install is chosen.
# shellcheck disable=SC2016 # expanded by the stub when it runs, not here
printf '#!/usr/bin/env bash\necho "brew $*" >> "%s"\n[[ "$1" == list ]] && exit 1\nexit 0\n' "${CALLS}" > "${STUBS}/brew"
chmod +x "${STUBS}"/*
printf '<metadata><versioning>\n    <latest>8.5.0.16571</latest>\n    <release>8.5.0.16571</release>\n</versioning></metadata>\n' > "${WORK}/metadata.xml"

# Core API stand-ins.
# shellcheck disable=SC2329  # called by the sourced files
log_info()  { echo "[INFO] $*" >&2; }
# shellcheck disable=SC2329
log_warn()  { echo "[WARN] $*" >&2; }
# shellcheck disable=SC2329
log_error() { echo "[ERROR] $*" >&2; }
# shellcheck disable=SC2329
get-elevation-command() { echo ""; }
# shellcheck disable=SC2329
_str_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# shellcheck disable=SC2329
_wb_declare_availability() { :; }
# shellcheck disable=SC2329
_wb_alias_availability() { :; }
# shellcheck disable=SC2329
_wb_fetch_verified() {
    echo "fetch_verified $1 | $3" >> "${CALLS}"
    [[ -n "${STUB_FETCH_FAIL:-}" ]] && return 1
    printf 'zip' > "$2"
}
# shellcheck disable=SC2329
_download_file_robust() {
    echo "download $1" >> "${CALLS}"
    # The stand-in for SonarSource's install.sh: records what it was run with
    # and puts a binary where the real one does.
    cat > "$2" <<SCRIPT
#!/usr/bin/env bash
echo "PROFILE=\${PROFILE:-unset}" >> "${CALLS}"
mkdir -p "\${HOME}/.local/share/sonarqube-cli/bin"
printf '#!/bin/sh\necho sonar\n' > "\${HOME}/.local/share/sonarqube-cli/bin/sonar"
chmod +x "\${HOME}/.local/share/sonarqube-cli/bin/sonar"
SCRIPT
}

export HOME="${WORK}/home"
unset XDG_DATA_HOME
export PATH="${STUBS}:${PATH}"
export WORKBENCH_OS=Linux WORKBENCH_ARCH=x86_64 WORKBENCH_DISTRO=rhel

# shellcheck disable=SC1090
source "${INSTALLERS}"
# shellcheck disable=SC1090
source "${SECURITY_SH}"

# ── install-secret-tool ──────────────────────────────────────────────────────

for pair in "rhel:dnf install -y libsecret" "debian:apt-get install -y libsecret-tools" \
            "suse:zypper install -y libsecret-tools" "arch:pacman -S --noconfirm libsecret"; do
    distro="${pair%%:*}"; want="${pair#*:}"
    : > "${CALLS}"
    WORKBENCH_DISTRO="${distro}" install-secret-tool >/dev/null 2>&1
    if grep -qx "${want}" "${CALLS}"; then
        ok "install-secret-tool on ${distro} runs '${want}'"
    else
        fail "install-secret-tool on ${distro}: calls were $(tr '\n' ';' < "${CALLS}")"
    fi
done

out="$(WORKBENCH_OS=Mac install-secret-tool 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'Linux only' <<<"${out}"; then
    ok "install-secret-tool refuses on macOS"
else
    fail "install-secret-tool on macOS: rc=${rc}, output: ${out}"
fi

# ── sonar-token-set / -get / -clear ──────────────────────────────────────────

: > "${CALLS}"; rm -f "${WORK}/secret-stdin"
printf '%s\n' "${TOKEN}" | sonar-token-set >/dev/null 2>&1; rc=$?
if [[ ${rc} -eq 0 ]] && grep -qx "secret-tool store --label=SonarQube token service sonarqube account scanner" "${CALLS}"; then
    ok "sonar-token-set stores under service sonarqube / account scanner"
else
    fail "sonar-token-set: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
if grep -q "${TOKEN}" "${CALLS}"; then
    fail "the token appeared in secret-tool's arguments"
else
    ok "the token is not in secret-tool's arguments"
fi
if [[ "$(cat "${WORK}/secret-stdin" 2>/dev/null)" == "${TOKEN}" ]]; then
    ok "the token reached secret-tool on stdin, without the newline"
else
    fail "secret-tool stdin was '$(cat "${WORK}/secret-stdin" 2>/dev/null)'"
fi

: > "${CALLS}"
printf '\n' | sonar-token-set >/dev/null 2>&1; rc=$?
if [[ ${rc} -ne 0 ]] && ! grep -q '^secret-tool store' "${CALLS}"; then
    ok "sonar-token-set stores nothing for an empty token"
else
    fail "sonar-token-set with an empty token: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi

got="$(STORED_TOKEN="${TOKEN}" sonar-token-get)"
if [[ "${got}" == "${TOKEN}" ]]; then ok "sonar-token-get prints the stored token"; else fail "sonar-token-get printed '${got}'"; fi

out="$(STORED_TOKEN="" sonar-token-get 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'sonar-token-set' <<<"${out}" && ! grep -q "${TOKEN}" <<<"${out}"; then
    ok "sonar-token-get with nothing stored fails and points at sonar-token-set"
else
    fail "sonar-token-get with nothing stored: rc=${rc}, output: ${out}"
fi

: > "${CALLS}"
sonar-token-clear >/dev/null 2>&1
if grep -qx "secret-tool clear service sonarqube account scanner" "${CALLS}"; then
    ok "sonar-token-clear clears service sonarqube / account scanner"
else
    fail "sonar-token-clear calls: $(tr '\n' ';' < "${CALLS}")"
fi

# ── _sonar_token_offer_store ─────────────────────────────────────────────────

# shellcheck disable=SC2329
_sonar_have_terminal() { return 0; }
# shellcheck disable=SC2329
_read_prompt() { printf -v "$2" '%s' "${STUB_REPLY:-n}"; }
# shellcheck disable=SC2329
_sonar_read_secret() { printf '%s' "${STUB_SECRET:-}"; }

: > "${CALLS}"
STORED_TOKEN="existing" STUB_REPLY=y STUB_SECRET="${TOKEN}" _sonar_token_offer_store >/dev/null 2>&1
if ! grep -q '^secret-tool store' "${CALLS}"; then
    ok "an already-stored token is left alone"
else
    fail "an existing token was overwritten"
fi

: > "${CALLS}"; rm -f "${WORK}/secret-stdin"
STORED_TOKEN="" STUB_REPLY=y STUB_SECRET="${TOKEN}" _sonar_token_offer_store >/dev/null 2>&1
if grep -qx "secret-tool store --label=SonarQube token service sonarqube account scanner" "${CALLS}" \
    && [[ "$(cat "${WORK}/secret-stdin" 2>/dev/null)" == "${TOKEN}" ]] && ! grep -q "${TOKEN}" "${CALLS}"; then
    ok "answering y stores the token on stdin, never on argv"
else
    fail "offer-store with y: calls $(tr '\n' ';' < "${CALLS}")"
fi

: > "${CALLS}"
STORED_TOKEN="" STUB_REPLY=n STUB_SECRET="${TOKEN}" _sonar_token_offer_store >/dev/null 2>&1
if ! grep -q '^secret-tool store' "${CALLS}"; then ok "answering n stores nothing"; else fail "stored a token after n"; fi

# shellcheck disable=SC2329
_sonar_have_terminal() { return 1; }
: > "${CALLS}"
out="$(STORED_TOKEN="" STUB_REPLY=y _sonar_token_offer_store 2>&1)"
if ! grep -q '^secret-tool store' "${CALLS}" && grep -q 'sonar-token-set' <<<"${out}"; then
    ok "without a terminal nothing is asked and sonar-token-set is suggested"
else
    fail "no-terminal path: calls $(tr '\n' ';' < "${CALLS}"), output: ${out}"
fi
# shellcheck disable=SC2329
_sonar_have_terminal() { return 0; }

# ── install-sonar-scanner (Linux archive) ────────────────────────────────────

# Keep the token step out of these runs.
# shellcheck disable=SC2329
_sonar_token_offer_store() { echo "token-offer" >> "${CALLS}"; }

ZIPBASE="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli"
: > "${CALLS}"
install-sonar-scanner >/dev/null 2>&1; rc=$?
if [[ ${rc} -eq 0 ]] \
    && grep -qx "fetch_verified ${ZIPBASE}-8.5.0.16571-linux-x64.zip | hashfile:${ZIPBASE}-8.5.0.16571-linux-x64.zip.sha256" "${CALLS}"; then
    ok "latest version comes from Maven metadata; the zip is fetched with its published .sha256"
else
    fail "install-sonar-scanner: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
link="${HOME}/.local/bin/sonar-scanner"
if [[ -L "${link}" && "$(readlink "${link}")" == "${HOME}/.local/share/sonar-scanner/sonar-scanner-8.5.0.16571-linux-x64/bin/sonar-scanner" && -x "${link}" ]]; then
    ok "sonar-scanner is installed under ~/.local/share/sonar-scanner and linked from ~/.local/bin"
else
    fail "sonar-scanner link is wrong: $(readlink "${link}" 2>&1)"
fi
if grep -qx "token-offer" "${CALLS}"; then ok "the token step runs after a scanner install"; else fail "the token step did not run"; fi

: > "${CALLS}"
install-sonar-scanner >/dev/null 2>&1
if ! grep -q '^fetch_verified' "${CALLS}"; then
    ok "re-running with the same version downloads nothing"
else
    fail "re-run downloaded again: $(tr '\n' ';' < "${CALLS}")"
fi

: > "${CALLS}"
SONAR_SCANNER_VERSION=8.4.0.16527 install-sonar-scanner >/dev/null 2>&1
if grep -q "fetch_verified ${ZIPBASE}-8.4.0.16527-linux-x64.zip " "${CALLS}" \
    && ! grep -q '^curl' "${CALLS}" \
    && [[ ! -d "${HOME}/.local/share/sonar-scanner/sonar-scanner-8.5.0.16571-linux-x64" ]] \
    && [[ "$(readlink "${link}")" == *8.4.0.16527* ]]; then
    ok "SONAR_SCANNER_VERSION pins a release without asking Maven, and the old version is removed"
else
    fail "pinned install: calls $(tr '\n' ';' < "${CALLS}"), link $(readlink "${link}")"
fi

for bad in '8.4' '8.4.0.1; rm -rf x' 'v8.4.0.16527' '../8.4.0.16527'; do
    : > "${CALLS}"
    out="$(SONAR_SCANNER_VERSION="${bad}" install-sonar-scanner 2>&1)"; rc=$?
    if [[ ${rc} -ne 0 ]] && ! grep -q '^fetch_verified' "${CALLS}" && grep -q 'SONAR_SCANNER_VERSION must look like' <<<"${out}"; then
        ok "SONAR_SCANNER_VERSION='${bad}' is rejected before any download"
    else
        fail "SONAR_SCANNER_VERSION='${bad}' was not rejected: rc=${rc}, output: ${out}"
    fi
done

rm -rf "${HOME}/.local/share/sonar-scanner" "${link}"
: > "${CALLS}"
out="$(STUB_FETCH_FAIL=1 install-sonar-scanner 2>&1)"; rc=$?
if [[ ${rc} -ne 0 && ! -e "${link}" ]] && ! ls "${HOME}/.local/share/sonar-scanner"/sonar-scanner-* >/dev/null 2>&1 \
    && ! ls -A "${HOME}/.local/share/sonar-scanner"/.install.* >/dev/null 2>&1; then
    ok "a failed download or checksum installs nothing and leaves no temp directory"
else
    fail "failed-download install: rc=${rc}, output: ${out}"
fi

printf '#!/bin/sh\necho mine\n' > "${link}"; chmod +x "${link}"
out="$(install-sonar-scanner 2>&1)"; rc=$?
if [[ ${rc} -ne 0 && ! -L "${link}" ]] && grep -q "isn't a workbench link" <<<"${out}"; then
    ok "an existing ~/.local/bin/sonar-scanner that isn't ours is not replaced"
else
    fail "foreign sonar-scanner: rc=${rc}, output: ${out}"
fi
rm -f "${link}"

out="$(WORKBENCH_ARCH=riscv64 install-sonar-scanner 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'no archive for Linux/riscv64' <<<"${out}"; then
    ok "an unsupported architecture fails clearly"
else
    fail "riscv64: rc=${rc}, output: ${out}"
fi

: > "${CALLS}"
WORKBENCH_ARCH=aarch64 install-sonar-scanner >/dev/null 2>&1
if grep -q 'linux-aarch64.zip ' "${CALLS}"; then ok "aarch64 gets the linux-aarch64 archive"; else fail "aarch64 calls: $(tr '\n' ';' < "${CALLS}")"; fi

: > "${CALLS}"
WORKBENCH_OS=Mac install-sonar-scanner >/dev/null 2>&1
if grep -qx 'brew install sonar-scanner' "${CALLS}" && ! grep -q '^fetch_verified' "${CALLS}"; then
    ok "macOS installs sonar-scanner with Homebrew"
else
    fail "macOS calls: $(tr '\n' ';' < "${CALLS}")"
fi

# ── install-sonar (SonarQube CLI) ────────────────────────────────────────────

rm -rf "${HOME}/.local"
: > "${CALLS}"
install-sonar >/dev/null 2>&1; rc=$?
if [[ ${rc} -eq 0 ]] \
    && grep -qx 'download https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.sh' "${CALLS}" \
    && grep -qx 'PROFILE=/dev/null' "${CALLS}"; then
    ok "install-sonar runs the downloaded script (from a file) with PROFILE=/dev/null so no rc file is edited"
else
    fail "install-sonar: rc=${rc}, calls: $(tr '\n' ';' < "${CALLS}")"
fi
link="${HOME}/.local/bin/sonar"
if [[ -L "${link}" && "$(readlink "${link}")" == "${HOME}/.local/share/sonarqube-cli/bin/sonar" && -x "${link}" ]]; then
    ok "sonar is linked into ~/.local/bin"
else
    fail "sonar link is wrong: $(readlink "${link}" 2>&1)"
fi

rm -f "${link}"; printf '#!/bin/sh\necho mine\n' > "${link}"; chmod +x "${link}"
out="$(install-sonar 2>&1)"; rc=$?
if [[ ${rc} -ne 0 && ! -L "${link}" ]] && grep -q "isn't a workbench link" <<<"${out}"; then
    ok "an existing ~/.local/bin/sonar that isn't ours is not replaced"
else
    fail "foreign sonar: rc=${rc}, output: ${out}"
fi
rm -f "${link}"

out="$(WORKBENCH_OS=Mac WORKBENCH_ARCH=x86_64 install-sonar 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'no SonarQube CLI build for Mac/x86_64' <<<"${out}"; then
    ok "an Intel Mac is refused (SonarSource's script would fetch an arm64 binary)"
else
    fail "Intel Mac: rc=${rc}, output: ${out}"
fi

# shellcheck disable=SC2329
_download_file_robust() { : > "$2"; }
out="$(install-sonar 2>&1)"; rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'download failed or was empty' <<<"${out}"; then
    ok "an empty install script is refused"
else
    fail "empty script: rc=${rc}, output: ${out}"
fi

# ── Static: never piped into a shell ─────────────────────────────────────────

if grep -vE '^[[:space:]]*#' "${INSTALLERS}" | grep -E 'curl[^|]*\|[[:space:]]*(ba|z)?sh\b|wget[^|]*\|[[:space:]]*(ba|z)?sh\b' >/dev/null; then
    fail "installers.sh pipes a download into a shell"
else
    ok "no download in installers.sh is piped into a shell"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
