#!/usr/bin/env bash
#
# Parses local_audio/apparmor.txt the way the Supervisor will, so a profile that cannot load is
# caught here rather than on somebody's machine.
#
# The profile is worth a point of the security rating -- see scripts/security_rating.sh and
# README.md's `## Security rating` -- but only if it actually loads. A typo in it has no local
# symptom at all: the image still builds, the smoke suite still passes, and the Supervisor
# silently installs the app unconfined and one point lower. Nothing else in this repository
# reads the file.
#
# Two things are checked, and they are the two ways the Supervisor's own handling of the file
# can fail:
#
#   1. It carries exactly one top-level profile name. supervisor/utils/apparmor.py's
#      get_profile_name() raises on none and on more than one, and its regex is anchored at
#      column zero -- so the indented child profiles inside are correctly not counted, and a
#      second profile accidentally left unindented would be.
#
#   2. With that name rewritten to an installed slug, apparmor_parser accepts it. The rewrite
#      is what adjust_profile() does at install time, and it matters here because the slug is
#      install-dependent: `local_` prefixed for a local app, repository-hash prefixed for a
#      store one. The file is parsed under both, since a profile is never loaded under the name
#      it is written with.
#
# `-Q` is --skip-kernel-load: the profile is compiled and rejected on a syntax error, but never
# handed to the kernel, so this needs no privilege and changes nothing about the host.
#
# Needs: bash, awk and apparmor_parser. No docker, no image, no Supervisor.
#
# Usage: scripts/apparmor_check.sh [PROFILE]        (default: local_audio/apparmor.txt)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

PROFILE="${1:-$SCRIPT_DIR/../local_audio/apparmor.txt}"
readonly PROFILE

# The two shapes an installed slug takes. Different lengths on purpose: a rewrite that assumed
# the name kept its width would pass one and fail the other.
readonly SLUGS='local_local_audio a0d7b954_local_audio'

die() {
    printf '::error::apparmor: %s\n' "$1" >&2
    exit 1
}

# get_profile_name(), as supervisor/utils/apparmor.py reads it: every line whose first column is
# `profile `, and the file is only valid when they all name the same one.
profile_names() {
    awk '{ sub(/\r$/, "") } /^profile [^ ]+/ { print $2 }' "$1" | sort -u
}

# adjust_profile(), which rewrites only the first occurrence on each matching line and leaves
# the rest of the file -- including the indented child profiles -- exactly as written.
rewrite_profile_name() {
    local from=$1 to=$2
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
    ' "$3"
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

        # The rewrite has to have taken, or the parse below would be checking the file as
        # written -- which is the one name it is never loaded under.
        grep -q "^profile $slug " "$candidate" ||
            die "rewriting '$original' to '$slug' did not take"

        # No --warn=all: most of what it reports is "rules not enforced", which is about the
        # kernel doing the parsing rather than about the profile, and it fires dozens of times
        # for the network and signal rules this one is mostly made of. A real warning would be
        # lost in it, and the set would move with the runner's kernel.
        # --skip-cache so nothing is read from or written to /etc/apparmor.d/cache: this runs
        # unprivileged, and a cache the parser cannot write to is a diagnostic that varies with
        # the machine rather than with the file being checked.
        if ! apparmor_parser --skip-kernel-load --skip-cache "$candidate" 2>&1 | sed 's/^/    /'; then
            die "apparmor_parser rejected the profile as '$slug'"
        fi
        printf '  parses as           %s\n' "$slug"
    done

    printf '\napparmor: the profile parses\n'
}

main
