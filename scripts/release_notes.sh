#!/usr/bin/env bash
#
# Assembles the body of the GitHub Release for a tag, out of the changelog sections that tag
# delivers.
#
# Not every bump is tagged -- 0.1.3 and 0.1.4 were bumped and then delivered together by v0.1.5 --
# so the body is every `## X.Y.Z` section strictly after the previous release's version through
# the one being released, rather than the section for the released version alone. That is what
# accounts for a store card whose version jumps by more than one, and it makes the accounting
# mechanical: where the range starts is decided by the previous tag, not by whoever is writing
# the release up.
#
# Not GitHub's generated notes, which are a list of pull requests. The changelog is written in a
# user-facing voice for the people the Release page is read by, and this is the second place it
# is shown.
#
# Needs: bash, awk, sed and grep.
#
# Usage: scripts/release_notes.sh --version X.Y.Z --previous [X.Y.Z|''] --image REPOSITORY
#                                 [--changelog PATH]
#
#   --previous is the version of the release before this one, and must be given even when it is
#   empty -- an empty value says "there is no previous release", which is a different thing from
#   having forgotten to look it up, and only one of the two should quote the whole changelog.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

VERSION=''
PREVIOUS=''
IMAGE=''
CHANGELOG="$SCRIPT_DIR/../local_audio/CHANGELOG.md"
have_previous=0

usage() {
    printf 'usage: %s --version X.Y.Z --previous [X.Y.Z|%s] --image REPOSITORY [--changelog PATH]\n' \
        "$0" "''" >&2
}

die() {
    printf '::error::release notes: %s\n' "$1" >&2
    exit 1
}

# A bare trailing flag must refuse with the usage line rather than trip `set -u` and die on an
# unbound variable having printed nothing that says what was wrong.
need_value() {
    [ "$1" -ge 2 ] || {
        usage
        exit 2
    }
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --version)
            need_value "$#"
            VERSION=$2
            shift 2
            ;;
        --previous)
            need_value "$#"
            PREVIOUS=$2
            have_previous=1
            shift 2
            ;;
        --image)
            need_value "$#"
            IMAGE=$2
            shift 2
            ;;
        --changelog)
            need_value "$#"
            CHANGELOG=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[ -n "$VERSION" ] || {
    usage
    exit 2
}
[ -n "$IMAGE" ] || {
    usage
    exit 2
}
[ "$have_previous" = 1 ] || {
    usage
    exit 2
}

readonly VERSION PREVIOUS IMAGE CHANGELOG

readonly SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$VERSION" =~ $SEMVER ]] || die "--version $VERSION is not MAJOR.MINOR.PATCH"
[ -z "$PREVIOUS" ] || [[ "$PREVIOUS" =~ $SEMVER ]] ||
    die "--previous $PREVIOUS is neither MAJOR.MINOR.PATCH nor empty"
# The repository, carrying no tag of its own: the lead line appends both `:$VERSION` and
# `:latest` to it, and a value that arrived already tagged would come out as `repo:tag:version`.
[[ "$IMAGE" =~ ^[a-z0-9._/-]+$ ]] ||
    die "--image $IMAGE is not a bare repository -- the tags are appended to it, so it must not carry one"

[ -f "$CHANGELOG" ] || die "$CHANGELOG does not exist -- there are no sections to quote"

# Field-by-field and numeric, so that 0.1.9 is below 0.1.10 -- which a string comparison, and a
# `sort` without -V, both get backwards.
version_lt() {
    awk -v a="$1" -v b="$2" '
        BEGIN {
            split(a, x, "."); split(b, y, ".")
            for (i = 1; i <= 3; i++)
                if (x[i] + 0 != y[i] + 0) exit !(x[i] + 0 < y[i] + 0)
            exit 1
        }'
}

[ -z "$PREVIOUS" ] || version_lt "$PREVIOUS" "$VERSION" ||
    die "--previous $PREVIOUS is not below --version $VERSION -- a release delivers the versions that came after the one before it"

# Every section in (PREVIOUS, VERSION], verbatim and in the order the changelog carries them,
# which is newest first. An empty PREVIOUS opens the range, which is the first release.
render_sections() {
    awk -v version="$VERSION" -v previous="$PREVIOUS" '
        function cmp(a, b,   x, y, i) {
            split(a, x, "."); split(b, y, ".")
            for (i = 1; i <= 3; i++) {
                if (x[i] + 0 < y[i] + 0) return -1
                if (x[i] + 0 > y[i] + 0) return 1
            }
            return 0
        }

        function emit() {
            while (pending > 0) { print ""; pending-- }
            print
            printed = 1
        }

        { sub(/\r$/, "") }

        # A fenced block is content, not structure. An example that shows a shell command
        # carries `#` comments, and reading one as a heading would end the section on the spot
        # and drop the rest of it out of the release.
        /^```/ { fence = !fence }

        !fence && /^## [0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$/ {
            keep = (previous == "" || cmp($2, previous) > 0) && cmp($2, version) <= 0
            if (keep) {
                # Exactly one blank line before the section, however many the last one trailed.
                if (printed) pending = 1
                emit()
            }
            next
        }

        # Any other level-one or level-two heading closes the section above it: the
        # `# Changelog` title at the top of the file, and an `## Unreleased` that nobody has
        # tagged. A `###` is a subheading inside a section and stays part of it.
        !fence && /^##?([^#]|$)/ { keep = 0; next }

        keep {
            # Held back rather than printed as it arrives, so that blank lines trailing a
            # section do not survive into the join.
            if ($0 ~ /^[[:space:]]*$/) {
                if (printed) pending++
                next
            }
            emit()
        }

        # Unbalanced, and every heading after the opening fence was read as content: `keep` never
        # cleared, so the body ran to the end of the file and swallowed every older section.
        # Loud, because what it produces otherwise is a plausible release rather than a broken
        # one.
        END {
            if (fence)
                print "::error::release notes: unclosed code fence in " FILENAME > "/dev/stderr"
            exit fence ? 1 : 0
        }' "$CHANGELOG"
}

sections="$(render_sections)"

# The headings that survived, which is both what to name in the sentence below and the check
# that the released version has a section at all. A tag whose version nobody wrote up would
# otherwise publish an empty Release body and look deliberate.
mapfile -t delivered < <(printf '%s\n' "$sections" | sed -nE 's/^## ([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p')

printf '%s\n' "${delivered[@]}" | grep -qxF "$VERSION" ||
    die "$CHANGELOG has no '## $VERSION' section -- write up the release before tagging it"

# Sections are read in file order, so the released version's has to be the first of them. What
# follows takes everything after it as the versions this release folded in, and a section written
# to the bottom of the changelog instead of the top would have the release announce itself as
# something it also carries.
[ "${delivered[0]}" = "$VERSION" ] ||
    die "$CHANGELOG puts ${delivered[0]} above $VERSION -- sections are read newest first, so the released version's must be the topmost one in range"

# "0.1.5, 0.1.4 and 0.1.3" -- read as prose on the Release page rather than parsed.
join_versions() {
    local -a items=("$@")
    local count=${#items[@]} head
    if [ "$count" = 1 ]; then
        printf '%s' "${items[0]}"
        return
    fi
    head="$(printf '%s, ' "${items[@]:0:count-1}")"
    printf '%s and %s' "${head%, }" "${items[count - 1]}"
}

# shellcheck disable=SC2016  # the backticks are Markdown code spans, not command substitution.
printf 'Published as `%s:%s` and `%s:latest`.\n' "$IMAGE" "$VERSION" "$IMAGE"

# Only when the release carries more than the version it is named for. The sentence states which
# versions those are and that nothing published them before; it does not reach for why they were
# not tagged, which is not derivable from anything CI can see. A release wanting that says so in
# a paragraph somebody adds afterwards.
if [ "${#delivered[@]}" -gt 1 ]; then
    folded=("${delivered[@]:1}")
    if [ "${#folded[@]}" = 1 ]; then
        printf '\nAlso carries %s, which was bumped without a release of its own and is first published here.\n' \
            "${folded[0]}"
    else
        printf '\nAlso carries %s, which were bumped without a release of their own and are first published here.\n' \
            "$(join_versions "${folded[@]}")"
    fi
fi

printf '\n%s\n' "$sections"
