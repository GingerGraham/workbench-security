#!/usr/bin/env bash
# tests/check-bitwarden-desktop-assets.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Exercises
# _bitwarden_desktop_fetch_verified and _bitwarden_desktop_pattern against a
# fixture shaped like the bitwarden/clients releases API. Asset names follow
# the electron-builder config (artifactName "${productName}-${version}-${arch}.${ext}",
# deb arch "amd64", rpm/AppImage arch "x86_64") and the upload steps in
# bitwarden/clients' .github/workflows/build-desktop.yml. curl and core's
# fetch helper are stubbed; no network is used.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLERS="${REPO_ROOT}/shell/installers.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/bin"
mkdir -p "${STUBS}"

B="https://github.com/bitwarden/clients/releases/download"
d() { printf '%064d' "$1"; }   # fake 64-hex digests: 000...01, 000...02, ...

# Releases are newest first: a beta, then the stable desktop release, then a
# cli release. Each asset lists "digest" before "browser_download_url", as the
# real API does. The stable .AppImage has a null digest.
cat > "${WORK}/releases.json" <<JSON
[
 {"tag_name":"desktop-v2026.9.1-beta.1","prerelease":true,"assets":[
  {"name":"Bitwarden-2026.9.1-beta.1-amd64.deb","digest":"sha256:$(d 9)","browser_download_url":"${B}/desktop-v2026.9.1-beta.1/Bitwarden-2026.9.1-beta.1-amd64.deb"},
  {"name":"Bitwarden-2026.9.1-beta.1-x86_64.rpm","digest":"sha256:$(d 9)","browser_download_url":"${B}/desktop-v2026.9.1-beta.1/Bitwarden-2026.9.1-beta.1-x86_64.rpm"}]},
 {"tag_name":"desktop-v2026.9.0","prerelease":false,"assets":[
  {"name":"Bitwarden-2026.9.0-amd64.deb","digest":"sha256:$(d 1)","browser_download_url":"${B}/desktop-v2026.9.0/Bitwarden-2026.9.0-amd64.deb"},
  {"name":"Bitwarden-2026.9.0-x86_64.rpm","digest":"sha256:$(d 2)","browser_download_url":"${B}/desktop-v2026.9.0/Bitwarden-2026.9.0-x86_64.rpm"},
  {"name":"Bitwarden-2026.9.0-x86_64.AppImage","digest":null,"browser_download_url":"${B}/desktop-v2026.9.0/Bitwarden-2026.9.0-x86_64.AppImage"}]},
 {"tag_name":"cli-v2026.9.0","prerelease":false,"assets":[
  {"name":"bw-linux-2026.9.0.zip","digest":"sha256:$(d 3)","browser_download_url":"${B}/cli-v2026.9.0/bw-linux-2026.9.0.zip"}]}
]
JSON
# Same, but the stable release's assets have no digests.
sed -E 's/"digest":"sha256:0*1"/"digest":null/; s/"digest":"sha256:0*2"/"digest":null/' "${WORK}/releases.json" > "${WORK}/releases-nodigest.json"

# shellcheck disable=SC2016  # ${FIXTURE} must expand in the stub, not here
printf '#!/usr/bin/env bash\ncat "${FIXTURE}"\n' > "${STUBS}/curl"
chmod +x "${STUBS}/curl"
export PATH="${STUBS}:${PATH}"

# shellcheck disable=SC2329  # called by the sourced installers.sh
log_info() { :; }
# shellcheck disable=SC2329
log_error() { :; }
# Copy of core 1.4's _wb_gh_asset_digest contract: the sha256 of the asset
# whose browser_download_url equals $2, from the "digest" that precedes it.
# shellcheck disable=SC2329
_wb_gh_asset_digest() {
    printf '%s' "$1" \
        | grep -oE '"(digest|browser_download_url)"[[:space:]]*:[[:space:]]*("[^"]*"|null)' \
        | sed -E 's/^"(digest|browser_download_url)"[[:space:]]*:[[:space:]]*"?([^"]*)"?$/\1 \2/' \
        | awk -v want="$2" '
            $1 == "digest" { last_digest = $2; next }
            $1 == "browser_download_url" { if ($2 == want) { print last_digest; exit } last_digest = "" }
          ' \
        | sed -n 's/^sha256://p'
}
FETCHED=""
# shellcheck disable=SC2329
_wb_fetch_verified() { FETCHED="$1 $3"; return 0; }
# shellcheck disable=SC1090
source "${INSTALLERS}"

# ── Patterns ─────────────────────────────────────────────────────────────────

export WORKBENCH_ARCH=x86_64
rpm_pat="$(_bitwarden_desktop_pattern rpm)"; deb_pat="$(_bitwarden_desktop_pattern deb)"
if [[ "${rpm_pat}" == 'x86_64\.rpm$' && "${deb_pat}" == 'amd64\.deb$' ]]; then
    ok "x86_64 patterns are x86_64\\.rpm\$ and amd64\\.deb\$"
else
    fail "unexpected x86_64 patterns: ${rpm_pat} ${deb_pat}"
fi
for a in aarch64 arm64; do
    export WORKBENCH_ARCH="${a}"
    if _bitwarden_desktop_pattern rpm >/dev/null 2>&1 || _bitwarden_desktop_pattern deb >/dev/null 2>&1; then
        fail "${a} should have no deb/rpm pattern (bitwarden/clients builds only a snap, tar.gz and flatpak for arm64)"
    else
        ok "${a} has no deb/rpm pattern"
    fi
done
export WORKBENCH_ARCH=x86_64

# ── Selection and digest ─────────────────────────────────────────────────────

export FIXTURE="${WORK}/releases.json"
FETCHED=""
_bitwarden_desktop_fetch_verified "${rpm_pat}" "${WORK}/b.rpm"; rc=$?
if [[ ${rc} -eq 0 && "${FETCHED}" == "${B}/desktop-v2026.9.0/Bitwarden-2026.9.0-x86_64.rpm $(d 2)" ]]; then
    ok "rpm: stable release chosen over the listed-first beta, with its own digest"
else
    fail "rpm selection wrong (rc=${rc}, got '${FETCHED}')"
fi
FETCHED=""
_bitwarden_desktop_fetch_verified "${deb_pat}" "${WORK}/b.deb"; rc=$?
if [[ ${rc} -eq 0 && "${FETCHED}" == "${B}/desktop-v2026.9.0/Bitwarden-2026.9.0-amd64.deb $(d 1)" ]]; then
    ok "deb: stable release chosen over the listed-first beta, with its own digest"
else
    fail "deb selection wrong (rc=${rc}, got '${FETCHED}')"
fi

FETCHED=""
_bitwarden_desktop_fetch_verified 'x86_64\.AppImage$' "${WORK}/b.ai"; rc=$?
if [[ ${rc} -ne 0 && -z "${FETCHED}" ]]; then
    ok "an asset with a null digest fails closed"
else
    fail "null-digest asset was fetched (rc=${rc}, '${FETCHED}')"
fi

export FIXTURE="${WORK}/releases-nodigest.json"
FETCHED=""
_bitwarden_desktop_fetch_verified "${rpm_pat}" "${WORK}/b.rpm"; rc=$?
if [[ ${rc} -ne 0 && -z "${FETCHED}" ]]; then
    ok "a release with no digests fails closed"
else
    fail "no-digest release was fetched (rc=${rc}, '${FETCHED}')"
fi

FETCHED=""
_bitwarden_desktop_fetch_verified 'no-such-asset$' "${WORK}/x"; rc=$?
if [[ ${rc} -ne 0 && -z "${FETCHED}" ]]; then
    ok "a pattern that matches no asset fails"
else
    fail "unmatched pattern did not fail (rc=${rc})"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
