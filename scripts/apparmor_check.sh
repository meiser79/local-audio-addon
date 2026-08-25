#!/usr/bin/env bash
#
# Parses local_audio/apparmor.txt the way the Supervisor will.
#
# Nothing else in this repository reads the file, and a typo in it has no local symptom: the
# image still builds and the smoke suite still passes, while the add-on installs unconfined and
# a point lower. Two things are checked, matching the two ways the Supervisor's own handling can
# fail -- get_profile_name() wants exactly one top-level profile, and adjust_profile() renames
# it to the installed slug before loading, so the file is never parsed under the name it is
# written with.
#
# Needs: bash, awk and apparmor_parser.
#
# Usage: scripts/apparmor_check.sh [PROFILE]        (default: local_audio/apparmor.txt)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

PROFILE="${1:-$SCRIPT_DIR/../local_audio/apparmor.txt}"
readonly PROFILE

# Both slug shapes, and deliberately different lengths: `local_` prefixed for a local add-on,
# repository-hash prefixed for a store one.
readonly SLUGS='local_local_audio a0d7b954_local_audio'

die() {
    printf '::error::apparmor: %s\n' "$1" >&2
    exit 1
}

# Anchored at column zero, as get_profile_name() is, so the indented child profiles inside are
# correctly not counted.
profile_names() {
    awk '{ sub(/\r$/, "") } /^profile [^ ]+/ { print $2 }' "$1" | sort -u
}

rewrite_profile_name() {
    local from=$1 to=$2 file=$3
    awk -v from="$from" -v to="$to" '
        { sub(/\r$/, "") }
        /^profile [^ ]+/ {
            i = index($0, from)
            if (i) {
                print substr($0, 1, i - 1) to substr($0, i + length(from))
                next
            }
        }
        { print }
    ' "$file"
}

main() {
    [ -f "$PROFILE" ] || die "no profile at $PROFILE"

    command -v apparmor_parser >/dev/null ||
        die 'apparmor_parser is not installed, so the profile went unparsed -- install the apparmor package rather than skipping this'

    printf 'apparmor: checking %s\n' "$PROFILE"

    local names count original
    names="$(profile_names "$PROFILE")"
    count="$(printf '%s\n' "$names" | grep -c . || true)"

    case $count in
        1) ;;
        0) die "no top-level profile in $PROFILE -- the Supervisor would refuse to install it" ;;
        *) die "$count top-level profiles in $PROFILE, and the Supervisor accepts exactly one: $(printf '%s' "$names" | tr '\n' ' ')" ;;
    esac
    original="$names"
    printf '  profile name        %s\n' "$original"

    local workdir
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/apparmor-check.XXXXXX")"
    # shellcheck disable=SC2064  # the path is wanted as it is now, not at trap time.
    trap "rm -rf -- '$workdir'" EXIT

    local slug candidate
    for slug in $SLUGS; do
        candidate="$workdir/$slug"
        rewrite_profile_name "$original" "$slug" "$PROFILE" >"$candidate"

        grep -q "^profile $slug " "$candidate" ||
            die "rewriting '$original' to '$slug' did not take"

        # Not --warn=all: nearly all of it is "rules not enforced", which tracks the kernel
        # doing the parsing rather than the file, and would bury a real warning. --skip-cache
        # because this runs unprivileged and cannot write /etc/apparmor.d/cache.
        if ! apparmor_parser --skip-kernel-load --skip-cache "$candidate" 2>&1 | sed 's/^/    /'; then
            die "apparmor_parser rejected the profile as '$slug'"
        fi
        printf '  parses as           %s\n' "$slug"
    done

    printf '\napparmor: the profile parses\n'
}

main
