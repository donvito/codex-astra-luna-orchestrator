#!/bin/sh

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
release_update_library=$script_dir/scripts/release-update.sh

if [ ! -r "$release_update_library" ]; then
    printf 'Error: release updater library is missing: %s\n' "$release_update_library" >&2
    exit 1
fi

# shellcheck source=scripts/release-update.sh
. "$release_update_library"
release_update_main "$script_dir" "$@"
