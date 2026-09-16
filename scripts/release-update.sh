#!/bin/sh

# Shared POSIX release-updater functions.  This file is sourced by setup.sh and
# update.sh; it intentionally does not dispatch anything when sourced.

release_update_repository='https://github.com/donvito/codex-astra-luna-orchestrator'
release_update_latest_endpoint="$release_update_repository/releases/latest"

release_update_usage() {
    printf '%s\n' 'Usage: update.sh [--check|--help]'
    printf '%s\n' '       setup.sh [--offline|--help]'
    printf '%s\n' ''
    printf '%s\n' 'update.sh checks the latest stable release and, after confirmation, downloads and runs its installer.'
    printf '%s\n' 'update.sh --check performs the release check without downloading or installing anything.'
    printf '%s\n' 'setup.sh --offline skips the automatic release check.'
}

release_update_confirm() {
    release_update_confirm_prompt=$1

    while :; do
        printf '%s [y/N] ' "$release_update_confirm_prompt"
        if ! IFS= read -r release_update_confirm_answer; then
            printf '\nRelease update cancelled: input ended before a decision was made.\n' >&2
            return 2
        fi

        case "$release_update_confirm_answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No|'') return 1 ;;
            *) printf '%s\n' 'Please answer yes or no.' ;;
        esac
    done
}

release_update_parse_effective_url() {
    release_update_parse_input=$1

    if release_update_parse_tag=$(printf '%s' "$release_update_parse_input" | awk '
        BEGIN {
            prefix = "https://github.com/donvito/codex-astra-luna-orchestrator/releases/tag/"
        }
        {
            if (NR != 1) {
                invalid = 1
            } else {
                candidate = $0
            }
        }
        END {
            if (invalid || NR != 1 || index(candidate, prefix) != 1) {
                exit 1
            }
            tag = substr(candidate, length(prefix) + 1)
            if (tag !~ /^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
                exit 1
            }
            print tag
        }
    '); then
        printf '%s\n' "$release_update_parse_tag"
        return 0
    fi

    return 1
}

release_update_get_latest_tag() {
    if ! command -v curl >/dev/null 2>&1; then
        printf '%s\n' 'Release update check failed: curl is required but was not found.' >&2
        return 1
    fi

    if ! release_update_effective_url=$(curl -fsSL \
        --proto '=https' \
        --proto-redir '=https' \
        --connect-timeout 5 \
        --max-time 5 \
        -o /dev/null \
        -w '%{url_effective}' \
        "$release_update_latest_endpoint"); then
        printf '%s\n' 'Release update check failed: unable to contact GitHub.' >&2
        return 1
    fi

    if ! release_update_latest_tag=$(release_update_parse_effective_url "$release_update_effective_url"); then
        printf '%s\n' 'Release update check failed: GitHub returned an unexpected stable-release URL.' >&2
        return 1
    fi

    printf '%s\n' "$release_update_latest_tag"
}

release_update_read_version() {
    release_update_version_path=$1

    if [ ! -f "$release_update_version_path" ] || [ -L "$release_update_version_path" ]; then
        return 1
    fi

    if release_update_normalized_version=$(awk '
        NR == 1 {
            value = $0
            sub(/\r$/, "", value)
            next
        }
        {
            invalid = 1
        }
        END {
            if (invalid || NR != 1 ||
                value !~ /^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
                exit 1
            }
            sub(/^v/, "", value)
            print value
        }
    ' "$release_update_version_path"); then
        printf '%s\n' "$release_update_normalized_version"
        return 0
    fi

    return 1
}

# Print one of: newer (the release is newer), same, or older (the local source
# is newer).  Component comparison is done digit by digit so it does not rely
# on sort -V or on an implementation-specific awk numeric range.
release_update_compare_versions() {
    release_update_current_version=$1
    release_update_release_version=$2

    awk -v current="$release_update_current_version" \
        -v release="$release_update_release_version" '
        function trim_leading_zeroes(value) {
            sub(/^0+/, "", value)
            if (value == "") {
                value = "0"
            }
            return value
        }
        function compare_component(left, right, left_trimmed, right_trimmed, i, ld, rd) {
            left_trimmed = trim_leading_zeroes(left)
            right_trimmed = trim_leading_zeroes(right)
            if (length(left_trimmed) < length(right_trimmed)) {
                return -1
            }
            if (length(left_trimmed) > length(right_trimmed)) {
                return 1
            }
            for (i = 1; i <= length(left_trimmed); i++) {
                ld = substr(left_trimmed, i, 1) + 0
                rd = substr(right_trimmed, i, 1) + 0
                if (ld < rd) {
                    return -1
                }
                if (ld > rd) {
                    return 1
                }
            }
            return 0
        }
        BEGIN {
            sub(/^v/, "", current)
            sub(/^v/, "", release)
            if (current !~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ ||
                release !~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
                exit 1
            }
            split(current, current_parts, ".")
            split(release, release_parts, ".")
            for (i = 1; i <= 3; i++) {
                result = compare_component(current_parts[i], release_parts[i])
                if (result < 0) {
                    print "newer"
                    exit 0
                }
                if (result > 0) {
                    print "older"
                    exit 0
                }
            }
            print "same"
        }
    '
}

release_update_announce() {
    release_update_announce_tag=$1
    release_update_announce_text=${2:-'Latest stable release'}
    printf '%s: %s\n' "$release_update_announce_text" "$release_update_announce_tag"
    printf '%s\n' "$release_update_repository/releases/tag/$release_update_announce_tag"
}

release_update_stage_is_safe() {
    if [ -z "${release_update_stage:-}" ] || [ -z "${release_update_tmp_base:-}" ]; then
        return 1
    fi
    if [ ! -d "$release_update_stage" ] || [ -L "$release_update_stage" ]; then
        return 1
    fi

    if ! release_update_stage_parent=$(CDPATH='' cd -- "$(dirname "$release_update_stage")" && pwd -P); then
        return 1
    fi
    if ! release_update_stage_real=$(CDPATH='' cd -- "$release_update_stage" && pwd -P); then
        return 1
    fi
    if [ "$release_update_stage_parent" != "$release_update_tmp_base" ]; then
        return 1
    fi
    if [ "$release_update_stage_real" = "$release_update_tmp_base" ]; then
        return 1
    fi

    case "$(basename "$release_update_stage_real")" in
        codex-astra-luna-update.*) return 0 ;;
        *) return 1 ;;
    esac
}

release_update_cleanup() {
    if release_update_stage_is_safe; then
        rm -rf "$release_update_stage_real"
    fi
    release_update_stage=
    release_update_stage_real=
    release_update_stage_parent=
    release_update_archive=
    release_update_listing=
    release_update_types=
    release_update_payload=
}

release_update_on_exit() {
    release_update_exit_status=$?
    release_update_cleanup
    trap - 0 1 2 3 15
    exit "$release_update_exit_status"
}

release_update_on_signal() {
    release_update_cleanup
    trap - 0 1 2 3 15
    exit 1
}

release_update_create_stage() {
    release_update_stage=
    release_update_stage_real=
    release_update_stage_parent=
    release_update_archive=
    release_update_listing=
    release_update_types=
    release_update_payload=

    release_update_tmp_base=${TMPDIR:-/tmp}
    if [ ! -d "$release_update_tmp_base" ]; then
        printf 'Release update failed: temporary directory does not exist: %s\n' "$release_update_tmp_base" >&2
        return 1
    fi
    if ! release_update_tmp_base=$(CDPATH='' cd -- "$release_update_tmp_base" && pwd -P); then
        printf '%s\n' 'Release update failed: temporary directory could not be resolved.' >&2
        return 1
    fi

    if ! release_update_stage=$(mktemp -d "$release_update_tmp_base/codex-astra-luna-update.XXXXXXXX"); then
        printf '%s\n' 'Release update failed: could not create a unique temporary stage.' >&2
        release_update_stage=
        return 1
    fi
    if ! release_update_stage_real=$(CDPATH='' cd -- "$release_update_stage" && pwd -P); then
        printf '%s\n' 'Release update failed: temporary stage could not be resolved.' >&2
        return 1
    fi
    if ! release_update_stage_is_safe; then
        printf '%s\n' 'Release update failed: temporary stage was outside the expected directory.' >&2
        return 1
    fi

    release_update_archive=$release_update_stage_real/release.tar.gz
    release_update_listing=$release_update_stage_real/archive-names.txt
    release_update_types=$release_update_stage_real/archive-types.txt
    release_update_payload=$release_update_stage_real/payload
    if ! mkdir "$release_update_payload"; then
        printf '%s\n' 'Release update failed: could not create the extraction directory.' >&2
        return 1
    fi
    return 0
}

release_update_validate_archive() {
    release_update_validate_archive_path=$1

    if ! tar -tzf "$release_update_validate_archive_path" > "$release_update_listing"; then
        printf '%s\n' 'Release update failed: the downloaded archive could not be listed.' >&2
        return 1
    fi
    if ! tar -tvzf "$release_update_validate_archive_path" > "$release_update_types"; then
        printf '%s\n' 'Release update failed: the downloaded archive metadata could not be read.' >&2
        return 1
    fi

    release_update_name_count=$(awk 'END { print NR + 0 }' "$release_update_listing")
    if [ "${release_update_name_count:-0}" -le 0 ]; then
        printf '%s\n' 'Release update failed: the downloaded archive is empty.' >&2
        return 1
    fi
    if ! awk -v expected="$release_update_name_count" '
        {
            count++
            type = substr($0, 1, 1)
            if (type != "d" && type != "-") {
                invalid = 1
            }
        }
        END {
            if (invalid || count != expected) {
                exit 1
            }
        }
    ' "$release_update_types"; then
        printf '%s\n' 'Release update failed: the archive contains a non-regular file or directory.' >&2
        return 1
    fi

    if ! release_update_archive_root=$(awk '
        function invalid_path(path, n, i, part) {
            if (path == "" || path ~ /\r/ || path ~ /\\/ ||
                path ~ /^\// || path ~ /^[A-Za-z]:[\\/]/ || path ~ /\/\//) {
                return 1
            }
            while (length(path) > 0 && substr(path, length(path), 1) == "/") {
                path = substr(path, 1, length(path) - 1)
            }
            if (path == "") {
                return 1
            }
            n = split(path, parts, "/")
            if (parts[1] == "" || parts[1] == "." || parts[1] == "..") {
                return 1
            }
            for (i = 1; i <= n; i++) {
                part = parts[i]
                if (part == "" || part == "." || part == "..") {
                    return 1
                }
            }
            return 0
        }
        {
            path = $0
            if (invalid_path(path)) {
                invalid = 1
                next
            }
            while (length(path) > 0 && substr(path, length(path), 1) == "/") {
                path = substr(path, 1, length(path) - 1)
            }
            split(path, parts, "/")
            if (root == "") {
                root = parts[1]
            }
            if (parts[1] != root) {
                invalid = 1
            }
            if (path == root "/setup.sh") {
                saw_setup = 1
            }
            if (path == root "/profiles" || index(path, root "/profiles/") == 1) {
                saw_profiles = 1
            }
            if (path == root "/AGENTS.md") {
                saw_agents = 1
            }
        }
        END {
            if (invalid || root == "" || !saw_setup || !saw_profiles || !saw_agents) {
                exit 1
            }
            print root
        }
    ' "$release_update_listing"); then
        printf '%s\n' 'Release update failed: archive paths are unsafe or the source root is incomplete.' >&2
        return 1
    fi

    if ! tar -xzf "$release_update_validate_archive_path" -C "$release_update_payload"; then
        printf '%s\n' 'Release update failed: the downloaded archive could not be extracted.' >&2
        return 1
    fi

    release_update_extracted_root=$release_update_payload/$release_update_archive_root
    if [ ! -d "$release_update_extracted_root" ] || [ -L "$release_update_extracted_root" ] ||
        [ ! -f "$release_update_extracted_root/setup.sh" ] || [ -L "$release_update_extracted_root/setup.sh" ] ||
        [ ! -d "$release_update_extracted_root/profiles" ] || [ -L "$release_update_extracted_root/profiles" ] ||
        [ ! -f "$release_update_extracted_root/AGENTS.md" ] || [ -L "$release_update_extracted_root/AGENTS.md" ]; then
        printf '%s\n' 'Release update failed: extracted release has an unexpected source layout.' >&2
        return 1
    fi

    return 0
}

release_update_install_release() {
    release_update_install_tag=$1
    release_update_install_archive_url=$release_update_repository/archive/refs/tags/$release_update_install_tag.tar.gz

    if ! release_update_create_stage; then
        release_update_cleanup
        return 1
    fi
    trap 'release_update_on_exit' 0
    trap 'release_update_on_signal' 1 2 3 15

    if ! command -v curl >/dev/null 2>&1; then
        printf '%s\n' 'Release update failed: curl is required but was not found.' >&2
        release_update_install_status=1
    elif ! curl -fsSL \
        --proto '=https' \
        --proto-redir '=https' \
        --connect-timeout 5 \
        --max-time 120 \
        -o "$release_update_archive" \
        "$release_update_install_archive_url"; then
        printf '%s\n' 'Release update failed: unable to download the selected release archive.' >&2
        release_update_install_status=1
    elif [ ! -f "$release_update_archive" ] || [ -L "$release_update_archive" ]; then
        printf '%s\n' 'Release update failed: the release archive was not downloaded as a regular file.' >&2
        release_update_install_status=1
    elif release_update_validate_archive "$release_update_archive"; then
        if CODEX_ORCHESTRATOR_SKIP_UPDATE_CHECK=1 sh "$release_update_extracted_root/setup.sh"; then
            release_update_install_status=0
        else
            release_update_install_status=$?
        fi
    else
        release_update_install_status=1
    fi

    release_update_cleanup
    trap - 0 1 2 3 15
    return "$release_update_install_status"
}

release_update_auto_result='continue'

release_update_auto_check() {
    release_update_source_root=$1
    release_update_auto_result='continue'

    if [ "${CODEX_ORCHESTRATOR_SKIP_UPDATE_CHECK:-}" = 1 ]; then
        return 0
    fi

    if ! release_update_local_version=$(release_update_read_version "$release_update_source_root/VERSION"); then
        printf '%s\n' 'Warning: local VERSION is missing or invalid; continuing local setup.' >&2
        return 0
    fi
    if ! release_update_auto_tag=$(release_update_get_latest_tag); then
        printf '%s\n' 'Warning: latest release could not be checked; continuing local setup.' >&2
        return 0
    fi

    if ! release_update_auto_comparison=$(release_update_compare_versions \
        "$release_update_local_version" "$release_update_auto_tag"); then
        printf '%s\n' 'Warning: release versions could not be compared; continuing local setup.' >&2
        return 0
    fi

    case "$release_update_auto_comparison" in
        newer)
            release_update_announce "$release_update_auto_tag" 'A newer stable release is available'
            if release_update_confirm "Download and run the $release_update_auto_tag installer?"; then
                if release_update_install_release "$release_update_auto_tag"; then
                    # Read by setup.sh after the release installer returns.
                    # shellcheck disable=SC2034
                    release_update_auto_result='exit'
                    return 0
                else
                    release_update_auto_install_status=$?
                    return "$release_update_auto_install_status"
                fi
            else
                release_update_auto_confirm_status=$?
                if [ "$release_update_auto_confirm_status" -eq 2 ]; then
                    return 1
                fi
                return 0
            fi
            ;;
        same)
            return 0
            ;;
        older)
            printf 'Local source version %s is newer than stable release %s; continuing local setup.\n' \
                "$release_update_local_version" "$release_update_auto_tag"
            return 0
            ;;
        *)
            printf '%s\n' 'Warning: release comparison returned an unexpected result; continuing local setup.' >&2
            return 0
            ;;
    esac
}

release_update_main() {
    release_update_main_source_root=$1
    shift
    release_update_main_mode=update
    release_update_main_help=no

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) release_update_main_mode=check ;;
            --help) release_update_main_help=yes ;;
            *)
                printf 'Error: unknown argument: %s\n' "$1" >&2
                release_update_usage >&2
                return 2
                ;;
        esac
        shift
    done

    if [ "$release_update_main_help" = yes ]; then
        release_update_usage
        return 0
    fi

    if ! release_update_main_tag=$(release_update_get_latest_tag); then
        return 1
    fi

    if release_update_main_local_version=$(release_update_read_version "$release_update_main_source_root/VERSION"); then
        if ! release_update_main_comparison=$(release_update_compare_versions \
            "$release_update_main_local_version" "$release_update_main_tag"); then
            printf '%s\n' 'Error: release versions could not be compared.' >&2
            return 1
        fi
    else
        release_update_main_local_version=
        release_update_main_comparison=
    fi

    if [ "$release_update_main_mode" = check ]; then
        release_update_announce "$release_update_main_tag" 'Latest stable release'
        case "$release_update_main_comparison" in
            newer)
                printf 'A newer stable release is available than local source version %s.\n' \
                    "$release_update_main_local_version"
                ;;
            same)
                printf 'Local source version %s matches the latest stable release.\n' \
                    "$release_update_main_local_version"
                ;;
            older)
                printf 'Local source version %s is newer than stable release %s.\n' \
                    "$release_update_main_local_version" "$release_update_main_tag"
                ;;
            *)
                printf '%s\n' 'Local source version is unavailable; release status could not be compared.'
                ;;
        esac
        return 0
    fi

    release_update_announce "$release_update_main_tag" 'Latest stable release'
    if release_update_confirm "Download and run the $release_update_main_tag installer?"; then
        if release_update_install_release "$release_update_main_tag"; then
            return 0
        else
            release_update_main_install_status=$?
            return "$release_update_main_install_status"
        fi
    else
        release_update_main_confirm_status=$?
        if [ "$release_update_main_confirm_status" -eq 2 ]; then
            return 1
        fi
        return 0
    fi
}
