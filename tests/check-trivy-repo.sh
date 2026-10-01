#!/usr/bin/env bash
# tests/check-trivy-repo.sh — workbench-security
# Plain bash, numbered OK:/FAIL: checks, matching this repo's existing
# tests/check-*.sh convention (no framework). Static checks on the Trivy
# repository definition: it must restrict itself to the trivy package and be
# rewritten on every run, and the release lookup must fail on HTTP errors.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

INSTALLERS="${REPO_ROOT}/shell/installers.sh"

# Body of _trivy-repo-rpm, from its opening line to the first closing brace
# at column 0.
body="$(awk '/^_trivy-repo-rpm\(\) \{/{f=1} f{print} f && /^\}/{exit}' "${INSTALLERS}")"

if [[ -n "${body}" ]]; then ok "found _trivy-repo-rpm"; else fail "_trivy-repo-rpm not found"; fi

if printf '%s\n' "${body}" | grep -qx 'includepkgs=trivy'; then
    ok "the trivy repo definition has includepkgs=trivy"
else
    fail "the trivy repo definition has no includepkgs=trivy"
fi

if printf '%s\n' "${body}" | grep -q 'return 0'; then
    fail "_trivy-repo-rpm still returns early when the repo file exists"
else
    ok "_trivy-repo-rpm has no early return, so the definition is rewritten every run"
fi

if grep -E 'curl -s ' "${INSTALLERS}" | grep -q 'aquasecurity/trivy'; then
    fail "the Trivy release lookup still uses curl -s"
else
    ok "the Trivy release lookup does not use curl -s"
fi

if grep -q 'curl -fsS https://api.github.com/repos/aquasecurity/trivy/releases/latest' "${INSTALLERS}"; then
    ok "the Trivy release lookup uses curl -fsS"
else
    fail "the Trivy release lookup does not use curl -fsS"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
    exit 0
fi
echo "${FAILED} of ${check_no} checks FAILED."
exit 1
