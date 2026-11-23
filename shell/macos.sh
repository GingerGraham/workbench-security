#!/usr/bin/env bash
# shell/macos.sh — workbench-security
# A `secret-tool` for macOS, backed by the login Keychain.
#
# Registered at tier: platform (workbench.yml), so core sources it only on
# macOS. The guard below repeats that, so a mistake in the manifest can't
# define this on Linux, where the real libsecret `secret-tool` is installed
# by `wb tools install secret-tool`.
#
# Why this exists: the SonarQube helpers in shell/security.sh
# (sonar-token-set/-get/-clear, `sq`) call `secret-tool` with libsecret's own
# syntax. This file accepts the same syntax and translates it to the
# `security` command, so those helpers (and any script written for Linux)
# work unchanged on a Mac.
#
#   secret-tool store --label=<text> service <value> account <value>
#                                  (the secret is read from stdin)
#   secret-tool lookup service <value> account <value>
#   secret-tool clear  service <value> account <value>
#
# Differences from libsecret's secret-tool:
#   - Keychain items have fixed fields, not free-form attributes. Only
#     `service` and `account` are accepted, and both are required.
#   - `search`, `--collection` and other libsecret-only features are refused.
#   - Values containing a double quote, a backslash or a newline are refused
#     (see _keychain_parse_attrs).
#   - `store` refuses an empty secret.
#
# The secret never appears in the argument list of any command. `store` hands
# it to `security -i` on stdin, hex-encoded so no character needs quoting.

[[ "${WORKBENCH_OS:-}" == "Mac" ]] || return 0

# Set by _keychain_parse_attrs, read by the callers.
_keychain_attr_service=""
_keychain_attr_account=""

# _keychain_hex
# Reads stdin and prints it as one unbroken line of hex digits.
_keychain_hex() {
    od -An -v -tx1 | tr -d ' \n'
}

# _keychain_parse_attrs [<attribute> <value> ...]
# Fills _keychain_attr_service and _keychain_attr_account. Returns 1, after
# saying why, for anything this file can't map onto a Keychain item.
#
# The values are later placed inside double quotes on a `security -i` command
# line. A double quote, backslash or newline would need escaping there, and
# the escaping rules of that parser aren't documented, so they're refused.
_keychain_parse_attrs() {
    _keychain_attr_service=""
    _keychain_attr_account=""
    while [[ $# -gt 0 ]]; do
        if [[ $# -lt 2 ]]; then
            log_error "secret-tool: attribute '$1' has no value"
            return 1
        fi
        case "$1" in
            service) _keychain_attr_service="$2" ;;
            account) _keychain_attr_account="$2" ;;
            *)
                log_error "secret-tool: attribute '$1' is not supported on macOS (only service and account)"
                return 1
                ;;
        esac
        shift 2
    done

    if [[ -z "${_keychain_attr_service}" || -z "${_keychain_attr_account}" ]]; then
        log_error "secret-tool: on macOS both 'service <value>' and 'account <value>' are required"
        return 1
    fi
    _keychain_value_is_quotable "${_keychain_attr_service}" || return 1
    _keychain_value_is_quotable "${_keychain_attr_account}" || return 1
    return 0
}

# _keychain_value_is_quotable <value>
# Returns 1, after saying why, when the value holds a character that can't be
# put safely inside double quotes on a `security -i` command line.
_keychain_value_is_quotable() {
    case "$1" in
        *'"'* | *"\\"* | *$'\n'*)
            log_error "secret-tool: values can't contain a double quote, a backslash or a newline on macOS"
            return 1
            ;;
    esac
    return 0
}

# _keychain_secret_store --label=<text> service <value> account <value>
_keychain_secret_store() {
    local label=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --label=*) label="${1#--label=}"; shift ;;
            -*)
                log_error "secret-tool: option '$1' is not supported on macOS"
                return 1
                ;;
            *) break ;;
        esac
    done

    _keychain_parse_attrs "$@" || return 1
    local service="${_keychain_attr_service}"
    local account="${_keychain_attr_account}"
    [[ -n "${label}" ]] || label="${service}"
    _keychain_value_is_quotable "${label}" || return 1

    # Read the secret as raw bytes, from the terminal (hidden) when stdin is
    # one, otherwise from stdin to the end, as libsecret's secret-tool does.
    local secret_hex token
    if [[ -t 0 ]]; then
        printf 'Password: ' >&2
        IFS= read -r -s token || { printf '\n' >&2; return 1; }
        printf '\n' >&2
        secret_hex="$(printf '%s' "${token}" | _keychain_hex)"
        token=""
    else
        secret_hex="$(_keychain_hex)"
    fi
    if [[ -z "${secret_hex}" ]]; then
        log_error "secret-tool: no secret given — nothing stored"
        return 1
    fi

    # `security -i` reads its commands from stdin, which keeps the secret out
    # of the argument list that `security add-generic-password -w <secret>`
    # would put in front of `ps`. -U updates an existing item in place.
    printf 'add-generic-password -a "%s" -s "%s" -l "%s" -X %s -U\n' \
        "${account}" "${service}" "${label}" "${secret_hex}" | security -i >/dev/null

    # `security -i` doesn't reliably report a failed command in its own exit
    # status, so read the item back and compare. A trailing newline is
    # ignored on both sides: `security -w` always adds one.
    local stored_hex
    stored_hex="$(security find-generic-password -a "${account}" -s "${service}" -w 2>/dev/null | _keychain_hex)"
    while [[ "${stored_hex}" == *0a ]]; do stored_hex="${stored_hex%0a}"; done
    while [[ "${secret_hex}" == *0a ]]; do secret_hex="${secret_hex%0a}"; done
    if [[ "${stored_hex}" != "${secret_hex}" ]]; then
        log_error "secret-tool: could not confirm the Keychain holds the new secret for service '${service}', account '${account}'"
        return 1
    fi
}

# _keychain_secret_lookup service <value> account <value>
# Prints the secret with no trailing newline. Prints nothing and returns 1
# when there is no such item, like libsecret's secret-tool.
_keychain_secret_lookup() {
    _keychain_parse_attrs "$@" || return 1

    local output rc
    output="$(security find-generic-password -a "${_keychain_attr_account}" -s "${_keychain_attr_service}" -w 2>&1)"
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
        printf '%s' "${output}"
        return 0
    fi
    # 44: item not found, which is not worth a message. Anything else (the
    # user refusing the Keychain prompt, a locked Keychain) is.
    if [[ ${rc} -ne 44 ]]; then
        printf '%s\n' "${output}" >&2
    fi
    return 1
}

# _keychain_secret_clear service <value> account <value>
# Removes the item. Succeeds when there is nothing to remove.
_keychain_secret_clear() {
    _keychain_parse_attrs "$@" || return 1

    local output rc
    output="$(security delete-generic-password -a "${_keychain_attr_account}" -s "${_keychain_attr_service}" 2>&1)"
    rc=$?
    if [[ ${rc} -ne 0 && ${rc} -ne 44 ]]; then
        printf '%s\n' "${output}" >&2
        return 1
    fi
    return 0
}

secret-tool() {
    local action=""
    if [[ $# -gt 0 ]]; then
        action="$1"
        shift
    fi
    case "${action}" in
        store)  _keychain_secret_store "$@" ;;
        lookup) _keychain_secret_lookup "$@" ;;
        clear)  _keychain_secret_clear "$@" ;;
        search)
            log_error "secret-tool: 'search' is not supported on macOS"
            return 1
            ;;
        *)
            {
                echo "Usage: secret-tool store --label=<text> service <value> account <value>   (secret on stdin)"
                echo "       secret-tool lookup service <value> account <value>"
                echo "       secret-tool clear service <value> account <value>"
            } >&2
            return 1
            ;;
    esac
}
