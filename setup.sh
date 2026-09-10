#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

cat <<'BANNER'
+---------------------------------------+
|    _    ____ _____ ____      _        |
|   / \  / ___|_   _|  _ \    / \       |
|  / _ \ \___ \ | | | |_) |  / _ \      |
| / ___ \ ___) || | |  _ <  / ___ \     |
|/_/   \_\____/ |_| |_| \_\/_/   \_\    |
|                                       |
|       O R C H E S T R A T O R         |
|   Plan and orchestrate with Astra.    |
|          Execute with Luna.           |
+---------------------------------------+
BANNER
printf '%s\n' 'Interactive project setup'
printf '%s' 'Target repository path: '
IFS= read -r target_path || exit 1

if [ -z "$target_path" ] || [ ! -d "$target_path" ]; then
    printf 'Error: target must be an existing directory: %s\n' "${target_path:-<empty>}" >&2
    exit 1
fi

target_dir=$(CDPATH= cd -- "$target_path" && pwd -P)
if [ "$target_dir" = "$script_dir" ]; then
    printf 'Error: target repository must be different from the setup source directory.\n' >&2
    exit 1
fi

confirm() {
    prompt=$1
    default_yes=$2
    if [ "$default_yes" = yes ]; then
        suffix='[Y/n]'
    else
        suffix='[y/N]'
    fi

    while :; do
        printf '%s %s ' "$prompt" "$suffix"
        if ! IFS= read -r answer; then
            printf '\nSetup cancelled: input ended before setup was complete.\n' >&2
            exit 1
        fi

        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            '') [ "$default_yes" = yes ] && return 0 || return 1 ;;
            *) printf '%s\n' 'Please answer yes or no.' ;;
        esac
    done
}

overwrite_paths() {
    source_path=$1
    destination_path=$2
    component_name=$(basename "$source_path")

    if [ -f "$source_path" ]; then
        if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
            printf '%s\n' "$component_name"
        else
            return
        fi
        return
    fi

    find "$source_path" -type f -print | while IFS= read -r source_file; do
        relative_path=${source_file#"$source_path"/}
        destination_file=$destination_path/$relative_path
        if [ -e "$destination_file" ] || [ -L "$destination_file" ]; then
            printf '%s\n' "$component_name/$relative_path"
        fi
    done
}

print_overwrites() {
    source_path=$1
    destination_path=$2

    overwrite_list=$(overwrite_paths "$source_path" "$destination_path")
    if [ -z "$overwrite_list" ]; then
        return
    fi

    printf '%s\n' 'WARNING: the following existing files will be overwritten:'
    printf '%s\n' "$overwrite_list" | sed 's/^/  - /'
}

merge_conflicts() {
    source_path=$1
    destination_path=$2

    find "$source_path" -type f -print | while IFS= read -r source_file; do
        relative_path=${source_file#"$source_path"/}
        destination_file=$destination_path/$relative_path
        if { [ -e "$destination_file" ] || [ -L "$destination_file" ]; } && [ ! -f "$destination_file" ]; then
            printf '%s\n' "$relative_path"
        fi
    done

    find "$source_path" -type d -print | while IFS= read -r source_directory; do
        if [ "$source_directory" = "$source_path" ]; then
            continue
        fi
        relative_path=${source_directory#"$source_path"/}
        destination_directory=$destination_path/$relative_path
        if { [ -e "$destination_directory" ] || [ -L "$destination_directory" ]; } && [ ! -d "$destination_directory" ]; then
            printf '%s\n' "$relative_path"
        fi
    done
}

select_plan() {
    printf '%s\n' 'Codex plan:'
    printf '%s\n' '  1) Pro  - GPT-6 Astra orchestrates, GPT-5.6 Luna executes, GPT-6 Astra reviews'
    printf '%s\n' '  2) Plus - GPT-5.6 Luna (max reasoning) orchestrates, GPT-5.6 Luna executes, GPT-6 Astra reviews'

    while :; do
        printf '%s' 'Select plan [1/2] (default 1): '
        if ! IFS= read -r answer; then
            printf '\nSetup cancelled: input ended before setup was complete.\n' >&2
            exit 1
        fi

        case "$answer" in
            1|pro|PRO|Pro|'') plan=pro; return ;;
            2|plus|PLUS|Plus) plan=plus; return ;;
            *) printf '%s\n' 'Please answer 1 (Pro) or 2 (Plus).' ;;
        esac
    done
}

# Build the .codex component for the selected plan in a temporary directory:
# config.plus.toml is never installed as-is; on Plus it becomes config.toml.
stage_codex() {
    staging_dir=$(mktemp -d)
    cp -R "$script_dir/.codex" "$staging_dir/.codex"
    if [ "$plan" = plus ]; then
        mv "$staging_dir/.codex/config.plus.toml" "$staging_dir/.codex/config.toml"
    else
        rm -f "$staging_dir/.codex/config.plus.toml"
    fi
    staged_codex=$staging_dir/.codex
}

cleanup_staging() {
    if [ -n "${staging_dir:-}" ] && [ -d "$staging_dir" ]; then
        rm -rf "$staging_dir"
    fi
}

copy_component() {
    name=$1
    source_path=${2:-$script_dir/$name}
    destination_path=$target_dir/$name
    component_installed=no

    if [ ! -e "$source_path" ]; then
        printf 'Error: setup source is missing: %s\n' "$source_path" >&2
        exit 1
    fi

    if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
        if [ ! -L "$destination_path" ] && [ -d "$source_path" ] && [ -d "$destination_path" ]; then
            linked_path=$(find "$destination_path" -type l -print -quit)
            if [ -n "$linked_path" ]; then
                printf 'Skipped %s: the existing target contains a symbolic link (%s).\n' \
                    "$name" "$linked_path" >&2
                return 0
            fi
            conflict_list=$(merge_conflicts "$source_path" "$destination_path")
            if [ -n "$conflict_list" ]; then
                printf 'Skipped %s: source and target types conflict at:\n' "$name" >&2
                printf '%s\n' "$conflict_list" | sed 's/^/  /' >&2
                return 0
            fi
        elif [ ! -L "$destination_path" ] && { [ -d "$source_path" ] && [ ! -d "$destination_path" ] || [ -f "$source_path" ] && [ ! -f "$destination_path" ]; }; then
            printf 'Skipped %s: source and target types are incompatible.\n' "$name" >&2
            return 0
        fi

        if [ -L "$destination_path" ]; then
            printf '%s\n' 'WARNING: the following symbolic link will be replaced:'
            printf '  - %s\n' "$name"
        else
            print_overwrites "$source_path" "$destination_path"
        fi
        if ! confirm "Update $name? New files will be added; only paths listed above will be replaced." no; then
            printf 'Skipped %s (existing target left unchanged).\n' "$name"
            return 0
        fi

        if [ -L "$destination_path" ]; then
            rm "$destination_path"
            cp -R "$source_path" "$destination_path"
        elif [ -d "$source_path" ] && [ -d "$destination_path" ]; then
            cp -R "$source_path"/. "$destination_path"/
        elif [ -f "$source_path" ] && [ -f "$destination_path" ]; then
            cp "$source_path" "$destination_path"
        fi
        printf 'Updated %s.\n' "$name"
    else
        cp -R "$source_path" "$destination_path"
        printf 'Installed %s.\n' "$name"
    fi
    component_installed=yes
}

plan=pro
staging_dir=
trap cleanup_staging EXIT
select_plan
stage_codex

installed=0
for component in .codex .agents AGENTS.md; do
    if confirm "Install $component?" yes; then
        if [ "$component" = .codex ]; then
            copy_component "$component" "$staged_codex"
        else
            copy_component "$component"
        fi
        if [ "$component_installed" = yes ]; then
            installed=$((installed + 1))
        fi
    else
        printf 'Skipped %s.\n' "$component"
    fi
done

printf '\nSetup complete. %s component(s) installed in %s (plan: %s).\n' "$installed" "$target_dir" "$plan"
printf '%s\n' 'See guides/ for optional Codex model and Fast-mode configurations.'
