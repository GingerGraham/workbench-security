#!/usr/bin/env bash
# shell/installers.sh — workbench-security
# install-cosign, install-trivy, install-bitwarden, install-bw-cli,
# install-1password, install-op-cli and their per-distro helpers. Ported
# from workbench-precursor's lazy/installers-security.sh. install-secret-tool,
# install-sonar-scanner and install-sonar (with the SonarQube token prompt)
# are new in this module.
#
# WORKBENCH_OS/WORKBENCH_DISTRO/WORKBENCH_ARCH are workbench-core Core API
# platform facts (contracts/core-api.md), replacing the precursor's
# DOTFILES_OS/DOTFILES_DISTRO. _download_file_robust/_ensure_npm/
# _npm_global_install come from workbench-core's Core API
# (lib/core/installers-common.sh) — not duplicated here.

# 1Password Linux packaging key (rsa4096, created 2017-05-18, expires
# 2032-05-16; uid "Code signing for 1Password <codesign@1password.com>").
# Confirmed by Graham on 2026-10-02 by running `gpg --show-keys
# --with-fingerprint` on the key served from _1PASSWORD_KEY_URL below. Not
# checked against 1Password's documentation page. The same value is also
# relied on by _1password-install-arch. Public OpenPGP fingerprint, not a
# secret.
_1PASSWORD_KEY_FPR="3FEF9748469ADBE15DA7CA80AC2D62742012EA22" # gitleaks:allow
_1PASSWORD_KEY_URL="https://downloads.1password.com/linux/keys/1password.asc"

# Trivy repository signing key. Verified 2026-10-13 against
# aquasecurity/trivy-repo (commit c3acd29, "chore: update public keys") and
# a good signature on the live deb InRelease; rotated 2026-04-17 after
# CVE-2026-33634. Public OpenPGP fingerprint, not a secret.
_TRIVY_KEY_FPR="825AD9036F7C850E6A6FED4935B8ACA44FD9CA9F" # gitleaks:allow

# _1password_apt_keyring
# Installs only the pinned 1Password key as the apt signed-by keyring
# (workbench-core D79). Shared by the desktop and CLI Debian paths.
_1password_apt_keyring() {
    _wb_apt_keyring_pinned "${_1PASSWORD_KEY_URL}" \
        /usr/share/keyrings/1password-archive-keyring.gpg "${_1PASSWORD_KEY_FPR}"
}

# _1password_debsig_keyring
# Installs only the pinned 1Password key as the debsig-verify keyring. That
# path is outside the directories _wb_apt_keyring_pinned accepts, so the key
# is filtered with _wb_key_extract_pinned and installed directly.
_1password_debsig_keyring() {
    local elevation_cmd tmp_dir rc
    elevation_cmd="$(get-elevation-command)" || return 1
    tmp_dir="$(mktemp -d)" || return 1
    if ! _download_file_robust "${_1PASSWORD_KEY_URL}" "${tmp_dir}/downloaded" \
        || ! _wb_key_extract_pinned "${tmp_dir}/downloaded" "${tmp_dir}/pinned.gpg" binary "${_1PASSWORD_KEY_FPR}"; then
        rm -rf "${tmp_dir}"
        return 1
    fi
    ${elevation_cmd} install -D -m 0644 "${tmp_dir}/pinned.gpg" \
        /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
    rc=$?
    rm -rf "${tmp_dir}"
    return ${rc}
}

# _1password_repo_rhel
# Pinned local key and package allowlist (workbench-core D79). Rewritten on
# every run so existing hosts converge.
_1password_repo_rhel() {
    # shellcheck disable=SC2016  # $basearch is for dnf, not the shell
    _wb_dnf_vendor_repo \
        --id 1password \
        --name "1Password Stable Channel" \
        --baseurl 'https://downloads.1password.com/linux/rpm/stable/$basearch' \
        --key-url "${_1PASSWORD_KEY_URL}" \
        --fingerprint "${_1PASSWORD_KEY_FPR}" \
        --include 1password \
        --include 1password-cli \
        --repo-gpgcheck
}

# ── cosign install (Sigstore signing) ────────────────────────────────────────
# Needed for full signature verification of tenv and of the tofu/terraform
# binaries tenv downloads (workbench-iac). Bootstrapped from the official
# release binary (verifying cosign with cosign is circular); package
# managers can replace it.
install-cosign() {
    log_info "Installing or updating cosign..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    if [[ "${WORKBENCH_OS}" == "Mac" ]]; then
        command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
        if brew list cosign &>/dev/null; then brew upgrade cosign; else brew install cosign; fi
        return $?
    fi

    local arch
    case "${WORKBENCH_ARCH}" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "cosign: unsupported architecture ${WORKBENCH_ARCH}"; return 1 ;;
    esac

    # Resolve the release explicitly so the asset can be verified against the
    # SHA-256 GitHub publishes for it, falling back to cosign's own checksums
    # file. _wb_fetch_verified writes via temp file + rename, so a re-install
    # can never splice old and new binaries (security review M2, M3).
    local api_response tag url expect
    api_response="$(curl -fsS https://api.github.com/repos/sigstore/cosign/releases/latest)" \
        || { log_error "cosign: could not query the latest release (network or GitHub API rate limit)"; return 1; }
    tag="$(printf '%s' "${api_response}" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -1)"
    [[ -z "${tag}" ]] && { log_error "cosign: could not determine the latest version"; return 1; }
    url="https://github.com/sigstore/cosign/releases/download/${tag}/cosign-linux-${arch}"
    expect="$(_wb_gh_asset_digest "${api_response}" "${url}")"
    [[ -z "${expect}" ]] && expect="sums:https://github.com/sigstore/cosign/releases/download/${tag}/cosign_checksums.txt"

    mkdir -p "${HOME}/.local/bin"
    log_info "cosign: downloading ${url##*/} (${tag}) ..."
    _wb_fetch_verified "${url}" "${HOME}/.local/bin/cosign" "${expect}" \
        || { log_error "cosign: download or verification failed"; return 1; }
    chmod +x "${HOME}/.local/bin/cosign"
    if command -v cosign &>/dev/null; then
        log_info "cosign installed: $(cosign version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    else
        log_error "cosign: not on PATH after install (is ~/.local/bin on PATH?)"; return 1
    fi
}

installed-cosign() {
    command -v cosign &>/dev/null
}

# ── Trivy install ─────────────────────────────────────────────────────────────
_trivy-repo-rpm() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    # Pinned local key and package allowlist (workbench-core D79). Rewritten
    # on every run so existing hosts converge. No --repo-gpgcheck: the repo
    # publishes no repomd.xml.asc.
    # shellcheck disable=SC2016  # $basearch is for dnf, not the shell
    _wb_dnf_vendor_repo \
        --id trivy \
        --name "Trivy" \
        --baseurl 'https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/' \
        --key-url "https://aquasecurity.github.io/trivy-repo/rpm/public.key" \
        --fingerprint "${_TRIVY_KEY_FPR}" \
        --include trivy \
        || return 1
    # check-update exits 100 when updates are available, which is success here;
    # only other non-zero codes are real errors. Without this, `_trivy-repo-rpm
    # && dnf install` would silently skip the install whenever an update exists.
    local rc=0
    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf check-update --refresh -y || rc=$?
    else
        ${elevation_cmd} yum check-update -y || rc=$?
    fi
    [[ ${rc} -eq 0 || ${rc} -eq 100 ]] && return 0
    log_error "trivy: package metadata refresh failed (exit ${rc})"
    return "${rc}"
}

# Pinned key only (workbench-core D79). No early return: a host that
# imported the pre-rotation key converges on the pinned keyring.
_trivy-repo-deb() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    _wb_apt_keyring_pinned "https://aquasecurity.github.io/trivy-repo/deb/public.key" \
        /usr/share/keyrings/trivy.gpg "${_TRIVY_KEY_FPR}" || return 1
    echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/trivy.list >/dev/null
    ${elevation_cmd} apt-get update
}

_trivy-install-linux() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    local ver
    local api_response
    api_response="$(curl -fsS https://api.github.com/repos/aquasecurity/trivy/releases/latest)" \
        || { log_error "Could not query the latest Trivy release (network or GitHub API rate limit)"; return 1; }
    ver="$(printf '%s' "${api_response}" \
        | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine Trivy version"; return 1; }

    if command -v trivy &>/dev/null; then
        local current
        current="$(trivy version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        [[ "${current}" == "${ver}" ]] && { log_info "Trivy ${ver} already installed"; return 0; }
    fi

    if command -v dnf &>/dev/null; then
        _trivy-repo-rpm && ${elevation_cmd} dnf install -y trivy
    elif command -v yum &>/dev/null; then
        _trivy-repo-rpm && ${elevation_cmd} yum install -y trivy
    elif command -v apt-get &>/dev/null; then
        _trivy-repo-deb && ${elevation_cmd} apt-get install -y trivy
    else
        log_error "No supported package manager for Trivy install"; return 1
    fi
}

_trivy-install-mac() {
    command -v brew &>/dev/null || { log_error "brew required on macOS"; return 1; }
    if command -v trivy &>/dev/null; then
        brew upgrade trivy
    else
        brew install trivy
    fi
}

install-trivy() {
    case "${WORKBENCH_OS}" in
        Linux) _trivy-install-linux ;;
        Mac)   _trivy-install-mac ;;
        *)     log_error "Unsupported OS for trivy"; return 1 ;;
    esac
}

installed-trivy() {
    command -v trivy &>/dev/null
}

# ── Bitwarden install ─────────────────────────────────────────────────────────
# _bitwarden_desktop_fetch_verified <asset-regex> <dest>
# Fetches the newest desktop-v* release asset of bitwarden/clients matching
# <asset-regex>, verified against the SHA-256 GitHub publishes for it
# (security review M3).
_bitwarden_desktop_fetch_verified() {
    local pattern="$1" dest="$2" releases_json url digest
    # per_page=100 (the API maximum): bitwarden/clients publishes cli-, web-,
    # browser- and desktop- releases in one list, so a short page can miss the
    # newest desktop release entirely.
    releases_json="$(curl -fsS 'https://api.github.com/repos/bitwarden/clients/releases?per_page=100')" \
        || { log_error "Could not query Bitwarden releases (network or GitHub API rate limit)"; return 1; }
    # Only stable desktop-vX.Y.Z releases: a -beta.N or -rc.N tag in the URL
    # path never matches, so a pre-release listed first is not installed.
    url="$(printf '%s' "${releases_json}" \
        | grep -Eo '"browser_download_url": *"[^"]+/desktop-v[0-9]+(\.[0-9]+)*/[^"]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/' \
        | grep -E "${pattern}" \
        | head -1)"
    [[ -z "${url}" ]] && { log_error "No Bitwarden desktop asset matching ${pattern}"; return 1; }
    digest="$(_wb_gh_asset_digest "${releases_json}" "${url}")"
    [[ -z "${digest}" ]] && { log_error "No published SHA-256 for ${url##*/} — refusing to install"; return 1; }
    _wb_fetch_verified "${url}" "${dest}" "${digest}"
}

# _bitwarden_desktop_pattern <deb|rpm>
# Prints the asset-name regex for this architecture, or fails. Only x86_64
# is supported for the deb/rpm paths; aarch64 errors rather than guessing.
_bitwarden_desktop_pattern() {
    case "${WORKBENCH_ARCH}:$1" in
        x86_64:rpm|amd64:rpm)   printf '%s' 'x86_64\.rpm$' ;;
        x86_64:deb|amd64:deb)   printf '%s' 'amd64\.deb$' ;;
        x86_64:appimage|amd64:appimage) printf '%s' 'x86_64\.AppImage$' ;;
        *) log_error "Bitwarden desktop: no verified ${1} package for ${WORKBENCH_ARCH}"; return 1 ;;
    esac
}

install-bitwarden() {
    log_info "Installing or updating Bitwarden..."
    [[ -z "${PACKAGE_MANAGER:-}" ]] && { detect-package-manager || return 1; }

    local elevation_cmd="" temp_dir
    if [[ "${PACKAGE_MANAGER}" != "brew" ]]; then
        sudo-test || { log_error "Administrator privileges required"; return 1; }
        elevation_cmd="$(get-elevation-command)" || return 1
    fi
    temp_dir="$(mktemp -d)"

    case "${PACKAGE_MANAGER}" in
        apt)
            local deb_pattern
            deb_pattern="$(_bitwarden_desktop_pattern deb)" || { rm -rf "${temp_dir}"; return 1; }
            _bitwarden_desktop_fetch_verified "${deb_pattern}" "${temp_dir}/bitwarden.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/bitwarden.deb" || true
            ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum)
            if command -v flatpak &>/dev/null; then
                # Signed by Flathub and published by Bitwarden — preferred on
                # Fedora over an unsigned local rpm.
                flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
                flatpak install -y flathub com.bitwarden.desktop
            else
                local rpm_pattern
                rpm_pattern="$(_bitwarden_desktop_pattern rpm)" || { rm -rf "${temp_dir}"; return 1; }
                _bitwarden_desktop_fetch_verified "${rpm_pattern}" "${temp_dir}/bitwarden.rpm" || { rm -rf "${temp_dir}"; return 1; }
                ${elevation_cmd} "${PACKAGE_MANAGER}" install -y "${temp_dir}/bitwarden.rpm"
            fi
            ;;
        zypper)
            local rpm_pattern
            rpm_pattern="$(_bitwarden_desktop_pattern rpm)" || { rm -rf "${temp_dir}"; return 1; }
            _bitwarden_desktop_fetch_verified "${rpm_pattern}" "${temp_dir}/bitwarden.rpm" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} zypper install -y "${temp_dir}/bitwarden.rpm"
            ;;
        pacman)
            # AUR installs are opt-in (workbench-core D100): bitwarden-bin
            # is an unreviewed build script. Without the opt-in, use the
            # verified AppImage.
            if command -v yay &>/dev/null && [[ "${WORKBENCH_ALLOW_AUR:-false}" == "true" ]]; then
                yay -S --noconfirm bitwarden-bin
            else
                if command -v yay &>/dev/null; then
                    log_info "AUR installs are off (WORKBENCH_ALLOW_AUR) — installing the verified AppImage. For the AUR package instead, run: yay -S bitwarden-bin"
                fi
                mkdir -p "${HOME}/Applications"
                # Verified against the SHA-256 GitHub publishes for the release
                # asset, not fetched through the bitwarden.com redirect.
                local ai_pattern
                ai_pattern="$(_bitwarden_desktop_pattern appimage)" || { rm -rf "${temp_dir}"; return 1; }
                _bitwarden_desktop_fetch_verified "${ai_pattern}" "${HOME}/Applications/Bitwarden.AppImage" || { rm -rf "${temp_dir}"; return 1; }
                chmod +x "${HOME}/Applications/Bitwarden.AppImage"
            fi
            ;;
        brew)
            brew install --cask bitwarden
            ;;
        *)
            if command -v flatpak &>/dev/null; then
                flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
                flatpak install -y flathub com.bitwarden.desktop
            else
                log_error "No supported install method found"; rm -rf "${temp_dir}"; return 1
            fi
            ;;
    esac

    rm -rf "${temp_dir}"
    log_info "Bitwarden installation complete"
}

# No installed-bitwarden predicate: the desktop app installs via five
# divergent paths with no unifying signal — apt/dnf/zypper (.deb/.rpm,
# binary plausibly `bitwarden`), pacman-via-yay (bitwarden-bin AUR
# package), pacman-without-yay (an AppImage at
# ~/Applications/Bitwarden.AppImage, never on PATH), a Homebrew CASK on
# macOS (a .app bundle, not a PATH binary — `command -v` cannot see it),
# and a Flatpak fallback (com.bitwarden.desktop, also never on PATH).
# Unlike install-1password above, install-bitwarden never verifies its
# own success either, so there's no existing check to mirror. Stays
# unresponsive to `wb tools upgrade`; fully installable via `wb tools
# install bitwarden`.

# ── Bitwarden CLI (bw) install ────────────────────────────────────────────────
# This is the headless CLI tool, separate from the Bitwarden desktop app.
# Used by workbench-gpg's gpg-export-bitwarden and gpg-import-bitwarden.
#
# After installing, authenticate with:
#   bw login
#   export BW_SESSION=$(bw unlock --raw)
install-bw-cli() {
    log_info "Installing or updating Bitwarden CLI (bw)..."

    case "${WORKBENCH_OS}" in
        Mac)
            if command -v brew &>/dev/null; then
                brew install bitwarden-cli
            else
                log_error "Homebrew required on macOS for Bitwarden CLI"
                return 1
            fi
            ;;
        Linux)
            if _ensure_npm; then
                _npm_global_install "@bitwarden/cli" || { log_error "Bitwarden CLI npm install failed"; return 1; }
            else
                # npm unavailable and could not be installed — pre-built binary
                log_info "npm unavailable — downloading pre-built binary from GitHub..."
                local bw_arch
                case "${WORKBENCH_ARCH}" in
                    x86_64)  bw_arch="linux-x64"   ;;
                    aarch64) bw_arch="linux-arm64" ;;
                    *) log_error "Unsupported architecture: ${WORKBENCH_ARCH}"; return 1 ;;
                esac

                local releases_json version
                releases_json="$(curl -fsS 'https://api.github.com/repos/bitwarden/clients/releases?per_page=100')" \
                    || { log_error "Could not query Bitwarden releases (network or GitHub API rate limit)"; return 1; }
                version="$(printf '%s' "${releases_json}" \
                    | grep '"tag_name"' | grep '"cli-' | head -1 \
                    | sed -E 's/.*"cli-v([0-9.]+)".*/\1/')"
                [[ -z "${version}" ]] && { log_error "Could not determine bw CLI version"; return 1; }

                local tmp_dir; tmp_dir="$(mktemp -d)"
                local zip_url="https://github.com/bitwarden/clients/releases/download/cli-v${version}/bw-${bw_arch}-${version}.zip"
                local digest; digest="$(_wb_gh_asset_digest "${releases_json}" "${zip_url}")"
                [[ -z "${digest}" ]] && { log_error "No published SHA-256 for ${zip_url##*/} — refusing to install"; rm -rf "${tmp_dir}"; return 1; }
                _wb_fetch_verified "${zip_url}" "${tmp_dir}/bw.zip" "${digest}" || { rm -rf "${tmp_dir}"; return 1; }
                unzip -q "${tmp_dir}/bw.zip" -d "${tmp_dir}"
                mkdir -p "${HOME}/.local/bin"
                install -m 755 "${tmp_dir}/bw" "${HOME}/.local/bin/bw"
                rm -rf "${tmp_dir}"
                log_info "bw CLI installed to ~/.local/bin/bw"
            fi
            ;;
        *)
            log_error "Unsupported OS for Bitwarden CLI install"
            return 1
            ;;
    esac

    if command -v bw &>/dev/null; then
        log_info "Bitwarden CLI installed: $(bw --version)"
        echo
        echo "  To authenticate:"
        echo "    bw login"
        echo "    export BW_SESSION=\$(bw unlock --raw)"
        echo
        echo "  To use with GPG exports (workbench-gpg):"
        echo "    gpg-export-bitwarden <fingerprint>"
    else
        log_warn "bw not found in PATH after install. You may need to restart your shell."
        log_warn "Expected location: ${HOME}/.local/bin/bw"
    fi
}

# Mirrors install-bw-cli's own final check.
installed-bw-cli() {
    command -v bw &>/dev/null
}

# ── 1Password desktop app install ────────────────────────────────────────────
# Official vendor repos per distro — package manager handles updates.
# GPG key: see _1PASSWORD_KEY_FPR at the top of this file.

_1password-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    _1password_apt_keyring || return 1

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/1password.list > /dev/null

    # The policy file has no published checksum; download to a temp file so an
    # HTTP error can never be installed as the policy.
    local pol_dir; pol_dir="$(mktemp -d)" || return 1
    if ! _download_file_robust https://downloads.1password.com/linux/debian/debsig/1password.pol "${pol_dir}/1password.pol" \
        || ! ${elevation_cmd} install -D -m 0644 "${pol_dir}/1password.pol" /etc/debsig/policies/AC2D62742012EA22/1password.pol; then
        rm -rf "${pol_dir}"
        log_error "1password: failed to install the debsig policy"
        return 1
    fi
    rm -rf "${pol_dir}"
    _1password_debsig_keyring || return 1

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y 1password
}

_1password-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    _1password_repo_rhel || return 1

    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y 1password
    else
        ${elevation_cmd} yum install -y 1password
    fi
}

_1password-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    _wb_rpm_import_pinned_key "${_1PASSWORD_KEY_URL}" 1password "${_1PASSWORD_KEY_FPR}" >/dev/null || return 1
    if ! zypper lr 2>/dev/null | grep -qi '1password'; then
        ${elevation_cmd} zypper addrepo https://downloads.1password.com/linux/rpm/stable/x86_64 1password
    else
        log_info "1Password zypper repo already present"
    fi
    # The pinned key is already imported above; --non-interactive rejects any
    # other key the repo presents rather than auto-trusting it (D79 —
    # review follow-up R2).
    ${elevation_cmd} zypper --non-interactive refresh 1password
    ${elevation_cmd} zypper install -y 1password
}

# Arch has only the AUR package (community-maintained), and AUR installs are
# opt-in (workbench-core D100): WORKBENCH_ALLOW_AUR=true in
# ~/.config/workbench/local/settings.sh. Without it, print the command to run
# and fail. Verification is makepkg's own: the PKGBUILD's validpgpkeys must
# match the signature on 1Password's tarball, so the 1Password key
# (_1PASSWORD_KEY_FPR) has to be in your keyring; a missing or wrong key
# stops the build.
_1password-install-arch() {
    if [[ "${WORKBENCH_ALLOW_AUR:-false}" != "true" ]]; then
        log_warn "1password on Arch comes from the AUR, which workbench installs only with WORKBENCH_ALLOW_AUR=true (in ~/.config/workbench/local/settings.sh)."
        if command -v yay &>/dev/null; then
            log_warn "To install it yourself, run: yay -S 1password"
        else
            log_warn "To install it yourself, run: git clone https://aur.archlinux.org/1password.git && cd 1password && makepkg -si"  # wb-allow-bare: text shown to the user, not run
        fi
        return 1
    fi
    if command -v yay &>/dev/null; then
        yay -S --noconfirm 1password
    else
        log_info "yay not found — building the 1password AUR package with makepkg..."
        local tmp_dir; tmp_dir="$(mktemp -d)" || return 1
        git clone https://aur.archlinux.org/1password.git "${tmp_dir}/1password" \
            || { log_error "Failed to clone AUR package"; rm -rf "${tmp_dir}"; return 1; }
        local rc=0
        ( builtin cd "${tmp_dir}/1password" && makepkg -si --noconfirm ) || rc=$?
        rm -rf "${tmp_dir}"
        return "${rc}"
    fi
}

_1password-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v 1password &>/dev/null; then
        brew upgrade --cask 1password
    else
        brew install --cask 1password
    fi
}

install-1password() {
    log_info "Installing or updating 1Password desktop app..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    case "${WORKBENCH_OS}" in
        Mac)
            _1password-install-mac
            ;;
        Linux)
            case "${WORKBENCH_DISTRO}" in
                rhel)   _1password-install-rhel   || return 1 ;;
                debian) _1password-install-debian || return 1 ;;
                suse)   _1password-install-suse   || return 1 ;;
                arch)   _1password-install-arch   || return 1 ;;
                *)
                    # Flatpak fallback for unknown distros
                    if command -v flatpak &>/dev/null; then
                        log_info "Unknown distro — installing via Flatpak..."
                        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
                        flatpak install -y flathub com.onepassword.OnePassword
                        log_warn "Flatpak install: SSH agent and system auth integration are not available."
                    else
                        log_error "Unknown distro and flatpak not available — cannot install 1Password"
                        return 1
                    fi
                    ;;
            esac
            ;;
        *)
            log_error "Unsupported OS for 1Password install"; return 1
            ;;
    esac

    if command -v 1password &>/dev/null; then
        log_info "1Password installed: $(1password --version 2>/dev/null | head -1)"
    else
        log_info "1Password installation complete. Launch from your application menu."
    fi
    echo
    echo "  To enable CLI integration, open 1Password → Settings → Developer"
    echo "  and enable 'Integrate with 1Password CLI'."
}

# Mirrors install-1password's own final check for every path except the
# flatpak fallback (unrecognised distros only), where install-1password
# itself installs com.onepassword.OnePassword with no `1password` binary
# on PATH — checked here directly via `flatpak info` so that path is no
# longer a known gap.
installed-1password() {
    command -v 1password &>/dev/null && return 0
    command -v flatpak &>/dev/null && flatpak info com.onepassword.OnePassword &>/dev/null
}

# ── 1Password CLI (op) install ────────────────────────────────────────────────
# Official vendor repos per distro, matching the desktop app repo setup.
# The 'op' binary needs the onepassword-cli group + setgid for biometric unlock
# via the 1Password desktop app integration.
#
# After installing, enable the desktop app integration:
#   1Password → Settings → Developer → Integrate with 1Password CLI
# Then authenticate:
#   op signin
#   op vault list

_op-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    _1password_apt_keyring || return 1

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/1password.list > /dev/null

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y 1password-cli
}

_op-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    _1password_repo_rhel || return 1

    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y 1password-cli
    else
        ${elevation_cmd} yum install -y 1password-cli
    fi
}

_op-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    _wb_rpm_import_pinned_key "${_1PASSWORD_KEY_URL}" 1password "${_1PASSWORD_KEY_FPR}" >/dev/null || return 1
    if ! zypper lr 2>/dev/null | grep -qi '1password'; then
        ${elevation_cmd} zypper addrepo https://downloads.1password.com/linux/rpm/stable/x86_64 1password
    fi
    # The pinned key is already imported above; --non-interactive rejects any
    # other key the repo presents rather than auto-trusting it (D79 —
    # review follow-up R2).
    ${elevation_cmd} zypper --non-interactive refresh 1password
    ${elevation_cmd} zypper install -y 1password-cli
}

_op-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v op &>/dev/null; then
        brew upgrade --cask 1password-cli
    else
        brew install --cask 1password-cli
    fi
}

# Root-free binary fallback — installs to ~/.local/bin.
# Note: without the onepassword-cli group + setgid the desktop app biometric
# integration won't work, but the CLI itself is fully functional.
_op-install-binary() {
    log_info "Installing op binary to ~/.local/bin (no root required)..."
    command -v unzip &>/dev/null || { log_error "unzip is required"; return 1; }

    local op_arch
    case "${WORKBENCH_ARCH}" in
        x86_64)        op_arch="amd64" ;;
        aarch64|arm64) op_arch="arm64" ;;
        i386|i686)     op_arch="386"   ;;
        armv7l)        op_arch="arm"   ;;
        *) log_error "Unsupported architecture: ${WORKBENCH_ARCH}"; return 1 ;;
    esac

    # Portable extraction — grep -P (PCRE lookbehind) is GNU-only and errors
    # on BSD grep (macOS default, though this specific fallback path is
    # Linux-only). sed's basic capture-group syntax works on both.
    local version
    version="$(curl -fsS https://app-updates.agilebits.com/product_history/CLI2 \
        | sed -n 's/.*<li class="[^"]*"><span class="version">\([^<]*\)<.*/\1/p' \
        | head -1)"
    # The version is interpolated into a download URL: accept only a plain
    # dotted number, so a malformed or hostile page cannot steer the URL.
    printf '%s' "${version}" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || version=""
    if [[ -z "${version}" ]]; then
        log_error "op: could not determine latest version — install via package manager instead (wb tools install op-cli handles this automatically on known distros)"
        return 1
    fi

    # Verified against the pinned 1Password signing key (the same
    # _1PASSWORD_KEY_FPR the repo paths pin): the zip carries a detached
    # op.sig, documented at 1password.dev/cli/verify. Fails closed.
    command -v gpgv &>/dev/null || { log_error "op: gpgv is required to verify the download (package gnupg/gpgv)"; return 1; }
    local zip_url="https://cache.agilebits.com/dist/1P/op2/pkg/v${version}/op_linux_${op_arch}_v${version}.zip"
    local tmp_dir; tmp_dir="$(mktemp -d)" || return 1
    if ! _download_file_robust "${zip_url}" "${tmp_dir}/op.zip" \
        || ! unzip -q "${tmp_dir}/op.zip" -d "${tmp_dir}/zip" \
        || [[ ! -f "${tmp_dir}/zip/op" || ! -f "${tmp_dir}/zip/op.sig" ]]; then
        log_error "op: download or unpack failed, or op.sig is missing — not installing"
        rm -rf "${tmp_dir}"
        return 1
    fi
    if ! _download_file_robust "${_1PASSWORD_KEY_URL}" "${tmp_dir}/key.asc" \
        || ! _wb_key_extract_pinned "${tmp_dir}/key.asc" "${tmp_dir}/pinned.gpg" binary "${_1PASSWORD_KEY_FPR}" \
        || ! gpgv --keyring "${tmp_dir}/pinned.gpg" "${tmp_dir}/zip/op.sig" "${tmp_dir}/zip/op" 2>"${tmp_dir}/gpgv.log"; then
        log_error "op: signature check against the pinned 1Password key failed — not installing"
        sed 's/^/    /' "${tmp_dir}/gpgv.log" >&2 2>/dev/null
        rm -rf "${tmp_dir}"
        return 1
    fi

    mkdir -p "${HOME}/.local/bin"
    install -m 755 "${tmp_dir}/zip/op" "${HOME}/.local/bin/op" || { rm -rf "${tmp_dir}"; return 1; }
    rm -rf "${tmp_dir}"

    log_info "op installed to ~/.local/bin/op"
    log_warn "Installed without onepassword-cli group — biometric unlock via desktop app will not work."
    log_warn "For full integration, re-install via package manager: wb tools install op-cli"
    [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]] \
        && log_warn "${HOME}/.local/bin is not on PATH — add it in ~/.config/workbench/local/settings.sh"
    return 0
}

install-op-cli() {
    log_info "Installing or updating 1Password CLI (op)..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    case "${WORKBENCH_OS}" in
        Mac)
            _op-install-mac
            ;;
        Linux)
            local ok=1
            case "${WORKBENCH_DISTRO}" in
                rhel)   _op-install-rhel   && ok=0 ;;
                debian) _op-install-debian && ok=0 ;;
                suse)   _op-install-suse   && ok=0 ;;
                *)
                    log_warn "No vendor repo for distro '${WORKBENCH_DISTRO}' — using binary install"
                    _op-install-binary && ok=0
                    ;;
            esac
            [[ "${ok}" -ne 0 ]] && { log_error "1Password CLI install failed"; return 1; }
            ;;
        *)
            log_error "Unsupported OS for op CLI install"; return 1
            ;;
    esac

    if command -v op &>/dev/null; then
        log_info "1Password CLI installed: $(op --version 2>/dev/null | head -1)"
        echo
        echo "  Enable desktop app integration first:"
        echo "    1Password → Settings → Developer → Integrate with 1Password CLI"
        echo
        echo "  Then authenticate:"
        echo "    op signin"
        echo "    op vault list"
    else
        log_warn "op not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}

# Mirrors install-op-cli's own final check.
installed-op-cli() {
    command -v op &>/dev/null
}

# ── secret-tool install (libsecret) ───────────────────────────────────────────
# secret-tool talks to the desktop's Secret Service keyring (GNOME Keyring,
# KeePassXC, ...). It is the command-line side of libsecret and is what the
# SonarQube token helpers (sonar-token-set/-get/-clear, `sq`) use. macOS keeps
# secrets in the Keychain and has no libsecret; shell/macos.sh defines a
# `secret-tool` function there that talks to the Keychain, so there is
# nothing to install.
install-secret-tool() {
    log_info "Installing or updating secret-tool (libsecret)..."
    [[ "${WORKBENCH_OS}" == "Linux" ]] \
        || { log_error "secret-tool: Linux only (on macOS, workbench-security's shell/macos.sh provides a Keychain-backed secret-tool; nothing to install)"; return 1; }

    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || return 1
    case "${WORKBENCH_DISTRO}" in
        rhel)
            if command -v dnf &>/dev/null; then
                ${elevation_cmd} dnf install -y libsecret
            else
                ${elevation_cmd} yum install -y libsecret
            fi
            ;;
        debian)
            ${elevation_cmd} apt-get update
            ${elevation_cmd} apt-get install -y libsecret-tools
            ;;
        suse)   ${elevation_cmd} zypper install -y libsecret-tools ;;
        arch)   ${elevation_cmd} pacman -S --noconfirm libsecret ;;
        *)      log_error "secret-tool: unknown distro (${WORKBENCH_DISTRO}) — install your distro's libsecret tools package"; return 1 ;;
    esac || { log_error "secret-tool: package install failed"; return 1; }

    command -v secret-tool &>/dev/null \
        || { log_error "secret-tool: not on PATH after install"; return 1; }
    log_info "secret-tool installed"
}

installed-secret-tool() {
    command -v secret-tool &>/dev/null
}

# ── SonarQube token in the keyring ────────────────────────────────────────────
# The attributes the token is stored under. The same two values are used by
# `sq` and sonar-token-set/-get/-clear in shell/security.sh — a separate file,
# because installers are sourced by `wb tools` on their own and never share a
# shell with the interactive helpers. tests/check-sonar.sh asserts they match.
_SONAR_TOKEN_SERVICE="sonarqube"
_SONAR_TOKEN_ACCOUNT="scanner"

# _sonar_read_secret <prompt>
# Reads one line from the terminal without echoing it and prints it on
# stdout, so the caller can hold it in a variable. Never on argv.
_sonar_read_secret() {
    local value
    printf '%s' "$1" >/dev/tty || return 1
    IFS= read -r -s value </dev/tty || { printf '\n' >/dev/tty; return 1; }
    printf '\n' >/dev/tty
    printf '%s' "${value}"
}

# True when there is a terminal to ask on. A function so tests can replace it.
_sonar_have_terminal() {
    { : </dev/tty; } 2>/dev/null
}

# _sonar_token_offer_store
# After a scanner install: when secret-tool is missing, offers to install it;
# when no token is stored yet and there is a terminal, offers to store one.
# Never fails the install — the scanner itself is already in place.
_sonar_token_offer_store() {
    if ! command -v secret-tool &>/dev/null; then
        if [[ "${WORKBENCH_OS}" != "Linux" ]]; then
            log_info "No secret-tool in this session. On macOS a new shell has a Keychain-backed one: store the SonarQube token there with sonar-token-set, or pass SONAR_TOKEN yourself"
            return 0
        fi
        log_info "secret-tool is not installed, so the SonarQube token can't be kept in the keyring."
        install-secret-tool || { log_warn "Skipping token storage — run 'wb tools install secret-tool' to retry"; return 0; }
    fi

    if [[ -n "$(secret-tool lookup service "${_SONAR_TOKEN_SERVICE}" account "${_SONAR_TOKEN_ACCOUNT}" 2>/dev/null)" ]]; then
        log_info "A SonarQube token is already stored in the keyring — leaving it unchanged (replace it with sonar-token-set)"
        return 0
    fi

    if ! _sonar_have_terminal; then
        log_info "No terminal to ask on — store a token later with: sonar-token-set"
        return 0
    fi

    local reply token
    _read_prompt "Store a SonarQube token in the keyring now? [y/N]: " reply
    case "$(_str_lower "${reply}")" in
        y|yes) ;;
        *) log_info "Skipped. Store one later with: sonar-token-set"; return 0 ;;
    esac

    token="$(_sonar_read_secret "SonarQube token (input hidden): ")" || { log_warn "Could not read a token"; return 0; }
    if [[ -z "${token}" ]]; then
        log_warn "No token entered — nothing stored"
        return 0
    fi
    # The token goes to secret-tool on stdin (printf is a builtin, so it is
    # never on any argv).
    if printf '%s' "${token}" | secret-tool store --label="SonarQube token" \
            service "${_SONAR_TOKEN_SERVICE}" account "${_SONAR_TOKEN_ACCOUNT}"; then
        log_info "SonarQube token stored — 'sq' and sonar-token-get read it from the keyring"
    else
        log_warn "secret-tool could not store the token (is a Secret Service keyring running and unlocked?)"
    fi
    token=""
}

# ── Shared by the sonar installers ────────────────────────────────────────────

# _sonar_link_into_local_bin <target> <name> <managed-root>
# Links ~/.local/bin/<name> to <target>. An existing <name> is replaced only
# when it is already a link into <managed-root> (ours); anything else there
# is the user's and is left alone.
_sonar_link_into_local_bin() {
    local target="$1" name="$2" managed_root="$3"
    local link="${HOME}/.local/bin/${name}" current
    mkdir -p "${HOME}/.local/bin" || return 1
    if [[ -L "${link}" ]]; then
        current="$(readlink "${link}")"
        case "${current}" in
            "${managed_root}"/*) ;;
            *) log_error "${link} already points to ${current}, not a workbench install — remove it to let workbench manage ${name}"; return 1 ;;
        esac
    elif [[ -e "${link}" ]]; then
        log_error "${link} already exists and isn't a workbench link — remove it to let workbench manage ${name}"
        return 1
    fi
    ln -sfn "${target}" "${link}" || { log_error "Could not link ${link}"; return 1; }
}

# ── sonar-scanner install ─────────────────────────────────────────────────────
# SonarScanner CLI: the zip with its own JRE from Sonar's distribution host on
# Linux (no Java needed), Homebrew on macOS. The latest version comes from
# Maven Central's metadata for the same release train — Sonar publishes no
# "latest" pointer and its directory listing is closed. The zip is checked
# against the .sha256 Sonar publishes beside it (integrity only: both come
# from the same host; the .asc signature is not checked, no signing key is
# pinned). Pin a release with SONAR_SCANNER_VERSION=8.4.0.16527.

_SONAR_SCANNER_DIST_URL="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli"
_SONAR_SCANNER_METADATA_URL="https://repo1.maven.org/maven2/org/sonarsource/scanner/cli/sonar-scanner-cli/maven-metadata.xml"

_sonar_scanner_latest_version() {
    curl -fsS "${_SONAR_SCANNER_METADATA_URL}" \
        | grep '<release>' \
        | sed -E 's/.*<release>([^<]+)<\/release>.*/\1/' \
        | head -1
}

# Prints the asset platform for this machine ("linux-x64"), or fails.
_sonar_scanner_platform() {
    case "${WORKBENCH_OS}/${WORKBENCH_ARCH}" in
        Linux/x86_64|Linux/amd64)   printf '%s' "linux-x64" ;;
        Linux/aarch64|Linux/arm64)  printf '%s' "linux-aarch64" ;;
        *) log_error "sonar-scanner: no archive for ${WORKBENCH_OS}/${WORKBENCH_ARCH}"; return 1 ;;
    esac
}

_sonar_scanner_install_archive() {
    command -v curl  &>/dev/null || { log_error "sonar-scanner: curl is required"; return 1; }
    command -v unzip &>/dev/null || { log_error "sonar-scanner: unzip is required"; return 1; }

    local platform ver
    platform="$(_sonar_scanner_platform)" || return 1
    if [[ -n "${SONAR_SCANNER_VERSION:-}" ]]; then
        ver="${SONAR_SCANNER_VERSION}"
        printf '%s' "${ver}" | grep -Eq '^[0-9]+(\.[0-9]+){3}$' \
            || { log_error "sonar-scanner: SONAR_SCANNER_VERSION must look like 8.4.0.16527, not '${ver}'"; return 1; }
    else
        ver="$(_sonar_scanner_latest_version)" \
            || { log_error "sonar-scanner: could not look up the latest version (network?)"; return 1; }
        printf '%s' "${ver}" | grep -Eq '^[0-9]+(\.[0-9]+){3}$' \
            || { log_error "sonar-scanner: unexpected latest version '${ver}' — pin one with SONAR_SCANNER_VERSION"; return 1; }
    fi
    log_info "sonar-scanner: version ${ver} (${platform})"

    local asset="sonar-scanner-cli-${ver}-${platform}.zip"
    local url="${_SONAR_SCANNER_DIST_URL}/${asset}"
    local install_root="${XDG_DATA_HOME:-${HOME}/.local/share}/sonar-scanner"
    local target="${install_root}/sonar-scanner-${ver}-${platform}"

    if [[ -x "${target}/bin/sonar-scanner" ]]; then
        log_info "sonar-scanner ${ver} is already installed"
        _sonar_link_into_local_bin "${target}/bin/sonar-scanner" sonar-scanner "${install_root}"
        return $?
    fi

    mkdir -p "${install_root}" || { log_error "sonar-scanner: cannot create ${install_root}"; return 1; }
    # Inside install_root so the final move is a rename, never a copy.
    local tmp_dir
    tmp_dir="$(mktemp -d "${install_root}/.install.XXXXXX")" || { log_error "sonar-scanner: mktemp failed"; return 1; }

    # An asset that doesn't exist comes back as 403 from Sonar's host, not 404.
    _wb_fetch_verified "${url}" "${tmp_dir}/${asset}" "hashfile:${url}.sha256" \
        || { log_error "sonar-scanner: download or verification failed for ${asset} (is ${ver} a real release?)"; rm -rf "${tmp_dir}"; return 1; }
    unzip -q "${tmp_dir}/${asset}" -d "${tmp_dir}/extract" \
        || { log_error "sonar-scanner: could not unpack ${asset}"; rm -rf "${tmp_dir}"; return 1; }

    # The zip holds exactly one top-level directory. (`command mv`: a host
    # alias must not run here, workbench-core D110.)
    set -- "${tmp_dir}/extract"/*/
    if [[ $# -ne 1 || ! -x "$1/bin/sonar-scanner" ]]; then
        log_error "sonar-scanner: ${asset} doesn't have the expected layout"
        rm -rf "${tmp_dir}"
        return 1
    fi
    command mv "${1%/}" "${target}" || { log_error "sonar-scanner: could not move it into ${install_root}"; rm -rf "${tmp_dir}"; return 1; }
    rm -rf "${tmp_dir}"

    _sonar_link_into_local_bin "${target}/bin/sonar-scanner" sonar-scanner "${install_root}" || return 1

    # Drop superseded versions of this platform.
    local old
    for old in "${install_root}"/sonar-scanner-*-"${platform}"; do
        [[ -d "${old}" && "${old}" != "${target}" ]] && rm -rf "${old}"
    done
    log_info "sonar-scanner ${ver} installed to ${target} (linked from ~/.local/bin)"
}

install-sonar-scanner() {
    log_info "Installing or updating sonar-scanner..."
    case "${WORKBENCH_OS}" in
        Mac)
            command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
            if brew list sonar-scanner &>/dev/null; then brew upgrade sonar-scanner; else brew install sonar-scanner; fi \
                || return 1
            ;;
        Linux) _sonar_scanner_install_archive || return 1 ;;
        *) log_error "Unsupported OS for sonar-scanner"; return 1 ;;
    esac

    _sonar_token_offer_store

    echo
    echo "  Point the scanner at your server with SONAR_HOST_URL (or sonar.host.url in a"
    echo "  project's sonar-project.properties). 'sq' runs it with the keyring token."
}

installed-sonar-scanner() {
    command -v sonar-scanner &>/dev/null
}

# ── SonarQube CLI (sonar) install ─────────────────────────────────────────────
# SonarSource's own install.sh, downloaded to a file and run — never piped
# into a shell. It does not verify the binary it fetches, and it appends a
# PATH line to the user's rc file; PROFILE=/dev/null (which the script
# honours) stops that, since workbench owns the rc files, and the binary is
# linked into ~/.local/bin instead.

_SONAR_CLI_SCRIPT_URL="https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.sh"

install-sonar() {
    log_info "Installing or updating the SonarQube CLI (sonar)..."
    command -v curl &>/dev/null || { log_error "sonar: curl is required"; return 1; }
    case "${WORKBENCH_OS}/${WORKBENCH_ARCH}" in
        Linux/x86_64|Linux/amd64|Linux/aarch64|Linux/arm64|Mac/arm64|Mac/aarch64) ;;
        # Its script assumes macos-arm64 on every Mac, so an Intel Mac would
        # get a binary it can't run.
        *) log_error "sonar: no SonarQube CLI build for ${WORKBENCH_OS}/${WORKBENCH_ARCH}"; return 1 ;;
    esac

    local tmp_script
    tmp_script="$(mktemp)" || { log_error "sonar: mktemp failed"; return 1; }
    if ! _download_file_robust "${_SONAR_CLI_SCRIPT_URL}" "${tmp_script}" || [[ ! -s "${tmp_script}" ]]; then
        log_error "sonar: install script download failed or was empty"
        rm -f "${tmp_script}"
        return 1
    fi
    if ! PROFILE=/dev/null bash "${tmp_script}"; then
        log_error "sonar: install script failed"
        rm -f "${tmp_script}"
        return 1
    fi
    rm -f "${tmp_script}"

    local managed_root="${HOME}/.local/share/sonarqube-cli"
    [[ -x "${managed_root}/bin/sonar" ]] \
        || { log_error "sonar: ${managed_root}/bin/sonar not found after install"; return 1; }
    _sonar_link_into_local_bin "${managed_root}/bin/sonar" sonar "${managed_root}" || return 1

    # SonarSource's script ends by telling you to add a PATH line, which we
    # asked it not to write.
    log_info "sonar linked into ~/.local/bin — no PATH change needed. Log in with: sonar auth login"
}

installed-sonar() {
    command -v sonar &>/dev/null
}
