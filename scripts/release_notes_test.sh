#!/usr/bin/env bash
#
# Unit checks for scripts/release_notes.sh.
#
# The release body is assembled once per release and read by everyone the release reaches, and
# nothing downstream of it would notice it being wrong: a body that quoted the wrong sections,
# or none, publishes exactly as happily as a correct one. So the range it selects is asserted
# here against the shipped changelog -- where "which sections does v0.1.5 deliver" has one right
# answer -- and its edges against scratch changelogs that carry the cases the real file does not
# yet have.
#
# Needs: bash, sed, grep and mktemp.
#
# Usage: scripts/release_notes_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
readonly NOTES="$SCRIPT_DIR/release_notes.sh"
readonly REAL_CHANGELOG="$SCRIPT_DIR/../local_audio/CHANGELOG.md"
readonly IMAGE=ghcr.io/music-assistant/local-audio-addon

FAILURES=0
SCRATCH_ROOT=""

pass() {
    printf '  ok   %s\n' "$1"
}

fail() {
    printf '  FAIL %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

step() {
    printf '\n%s\n' "$1"
}

assert_equal() {
    local want=$1 got=$2 what=$3
    if [ "$want" = "$got" ]; then
        pass "$what"
    else
        fail "$what"
        printf '    want: %q\n    got:  %q\n' "$want" "$got" >&2
    fi
}

# The body, or `error` when the script refused to produce one -- a distinct outcome from a body,
# so a refusal is never mistaken for an empty release.
body_of() {
    local out=''
    if ! out="$("$NOTES" --image "$IMAGE" "$@" 2>/dev/null)"; then
        printf 'error'
        return
    fi
    printf '%s' "$out"
}

status_of() {
    local status=0
    "$NOTES" --image "$IMAGE" "$@" >/dev/null 2>&1 || status=$?
    printf '%s' "$status"
}

# The `## X.Y.Z` headings the body carries, in the order it carries them.
assert_delivers() {
    local want=$1 what=$2
    shift 2
    local body got
    body="$(body_of "$@")"
    if [ "$body" = error ]; then
        fail "$what -- the script exited non-zero"
        return
    fi
    got="$(printf '%s\n' "$body" |
        sed -nE 's/^## ([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' | tr '\n' ' ')"
    assert_equal "$want" "${got% }" "$what"
}

# The exit status is what CI rides on, so a refusal is asserted as a status rather than as an
# absent body: a script that printed an error and exited 0 would publish the empty release it
# was complaining about.
assert_refuses() {
    local want=$1 what=$2
    shift 2
    assert_equal "$want" "$(status_of "$@")" "$what"
}

check_the_shipped_changelog() {
    step 'the changelog as it stands'

    # Every tagged release in this repository, and the versions each one actually delivered.
    # v0.1.5 and v0.1.7 are the whole point: 0.1.3, 0.1.4 and 0.1.6 were bumped and written up
    # and then went out under a later tag, which is why the store card's version jumps.
    assert_delivers '0.1.8' 'v0.1.8 delivers only 0.1.8' \
        --version 0.1.8 --previous 0.1.7 --changelog "$REAL_CHANGELOG"
    assert_delivers '0.1.7 0.1.6' 'v0.1.7 delivers 0.1.7 and the untagged 0.1.6' \
        --version 0.1.7 --previous 0.1.5 --changelog "$REAL_CHANGELOG"
    assert_delivers '0.1.5 0.1.4 0.1.3' 'v0.1.5 delivers 0.1.5 and the untagged 0.1.4 and 0.1.3' \
        --version 0.1.5 --previous 0.1.2 --changelog "$REAL_CHANGELOG"
    assert_delivers '0.1.2' 'v0.1.2 delivers only 0.1.2' \
        --version 0.1.2 --previous 0.1.1 --changelog "$REAL_CHANGELOG"
    assert_delivers '0.1.1' 'v0.1.1 delivers only 0.1.1' \
        --version 0.1.1 --previous 0.1.0 --changelog "$REAL_CHANGELOG"

    # The first release, which has no previous tag to start the range at. Nothing preceded 0.1.0
    # in the file, so "everything up to and including it" is that one section -- but the empty
    # `--previous` is what is being exercised, not the count.
    assert_delivers '0.1.0' 'the first release takes an empty --previous' \
        --version 0.1.0 --previous '' --changelog "$REAL_CHANGELOG"

    # 0.1.0 alone cannot tell an open range from a single section, being the oldest thing in the
    # file. This can: an empty --previous has to reach past 0.1.1 all the way down.
    assert_delivers '0.1.2 0.1.1 0.1.0' 'an empty --previous opens the range rather than closing it' \
        --version 0.1.2 --previous '' --changelog "$REAL_CHANGELOG"
}

check_the_lead_line() {
    step 'the line the body opens with'

    local body
    body="$(body_of --version 0.1.8 --previous 0.1.7 --changelog "$REAL_CHANGELOG")"
    assert_equal "Published as \`$IMAGE:0.1.8\` and \`$IMAGE:latest\`." \
        "$(printf '%s\n' "$body" | head -1)" \
        'the body opens by naming the image and both tags it was published under'

    # The sentence exists only where it says something the headings do not: with one section
    # nothing was folded in and there is nothing to account for.
    if printf '%s\n' "$body" | grep -q '^Also carries'; then
        fail 'a release delivering one version does not claim to carry anything else'
    else
        pass 'a release delivering one version does not claim to carry anything else'
    fi

    body="$(body_of --version 0.1.5 --previous 0.1.2 --changelog "$REAL_CHANGELOG")"
    assert_equal 'Also carries 0.1.4 and 0.1.3, which were bumped without a release of their own and are first published here.' \
        "$(printf '%s\n' "$body" | sed -n '/^Also carries/p')" \
        'a release that skips versions names the ones it folds in'

    # Singular, because v0.1.7 folded in exactly one. A sentence that said "which were bumped"
    # of a single version would be the sort of wrong nothing downstream would catch.
    body="$(body_of --version 0.1.7 --previous 0.1.5 --changelog "$REAL_CHANGELOG")"
    assert_equal 'Also carries 0.1.6, which was bumped without a release of its own and is first published here.' \
        "$(printf '%s\n' "$body" | sed -n '/^Also carries/p')" \
        'one folded-in version is written in the singular'

    # The layout the two joins above produce, which nothing else asserts: each part separated
    # from the next by exactly one blank line, and the first section following them.
    body="$(body_of --version 0.1.5 --previous 0.1.2 --changelog "$REAL_CHANGELOG")"
    assert_equal "Published as \`$IMAGE:0.1.5\` and \`$IMAGE:latest\`.

Also carries 0.1.4 and 0.1.3, which were bumped without a release of their own and are first published here.

## 0.1.5" \
        "$(printf '%s\n' "$body" | head -5)" \
        'the body opens lead, blank, sentence, blank, section'
}

check_the_sections_are_verbatim() {
    step 'the sections are quoted rather than rewritten'

    # A scratch file rather than the shipped one, so the expected body can be written out in
    # full: the point here is that every character between the headings survives, which an
    # assertion on the headings alone cannot say.
    local changelog="$SCRATCH_ROOT/verbatim.md"
    cat >"$changelog" <<'CHANGELOG'
# Changelog

## 1.2.0

Built on something, and through it something else.

- A bullet with `code`, **bold** and an em dash — in it.
  Wrapped onto a second line.


## 1.1.0

- The section above trails two blank lines; this one must still be one away.

## 1.0.0

Initial release.
CHANGELOG

    local want got
    # shellcheck disable=SC2016  # the backticks are Markdown code spans in the expected body.
    want='## 1.2.0

Built on something, and through it something else.

- A bullet with `code`, **bold** and an em dash — in it.
  Wrapped onto a second line.

## 1.1.0

- The section above trails two blank lines; this one must still be one away.'

    # Everything below the lead line, which is the part that came out of the changelog.
    got="$(body_of --version 1.2.0 --previous 1.0.0 --changelog "$changelog" |
        sed -n '/^## /,$p')"
    assert_equal "$want" "$got" 'the sections come through verbatim, one blank line apart'
}

check_versions_are_compared_as_numbers() {
    step 'versions are numbers, not strings'

    # The whole reason the comparison is field-by-field. Sorted as text, 1.1.10 is below 1.1.9,
    # so a release of 1.1.10 would drop its own section and quote its predecessor instead.
    local changelog="$SCRATCH_ROOT/numeric.md"
    cat >"$changelog" <<'CHANGELOG'
# Changelog

## 1.1.10

Ten.

## 1.1.9

Nine.

## 1.1.2

Two.
CHANGELOG

    assert_delivers '1.1.10' '1.1.10 is above 1.1.9, not below it' \
        --version 1.1.10 --previous 1.1.9 --changelog "$changelog"
    assert_delivers '1.1.10 1.1.9' 'a range spanning the ten and the nine carries both' \
        --version 1.1.10 --previous 1.1.2 --changelog "$changelog"
}

check_headings_bound_the_sections() {
    step 'headings that are not releases'

    local changelog="$SCRATCH_ROOT/headings.md"
    cat >"$changelog" <<'CHANGELOG'
# Changelog

## Unreleased

- Not written up under a version yet, and not part of any release.

## 1.1.0

### Fixed

- A subheading inside a section stays part of it.

## 1.0.0

Initial release.
CHANGELOG

    assert_delivers '1.1.0' 'an unversioned heading is not folded into the release below it' \
        --version 1.1.0 --previous 1.0.0 --changelog "$changelog"

    local body
    body="$(body_of --version 1.1.0 --previous 1.0.0 --changelog "$changelog")"
    if printf '%s\n' "$body" | grep -q 'Unreleased'; then
        fail 'the Unreleased section is left out of the body'
    else
        pass 'the Unreleased section is left out of the body'
    fi
    if printf '%s\n' "$body" | grep -q '^### Fixed$'; then
        pass 'a subheading inside a release section is kept'
    else
        fail 'a subheading inside a release section is kept'
    fi
}

check_fenced_blocks_are_content() {
    step 'fenced blocks are content, not structure'

    # A changelog entry showing a command is ordinary, and a shell comment inside one starts
    # with the same character a heading does. Read as a heading it would end the section there
    # and drop the rest of the entry out of the release -- a body that looks written rather
    # than truncated.
    local changelog="$SCRATCH_ROOT/fenced.md"
    cat >"$changelog" <<'CHANGELOG'
# Changelog

## 2.0.0

Run this first:

```sh
# raise the output level
ha audio volume output 100
```

- The bullet after the block is still part of this section.

## 1.0.0

Initial release.
CHANGELOG

    assert_delivers '2.0.0' 'a fenced block does not close the section around it' \
        --version 2.0.0 --previous 1.0.0 --changelog "$changelog"

    # A fence nobody closed leaves every later heading unread, so the body would run to the end
    # of the file and announce versions that shipped months ago as newly published.
    local unclosed="$SCRATCH_ROOT/unclosed-fence.md"
    sed '/^```$/d' "$changelog" >"$unclosed"
    assert_refuses 1 'a code fence nobody closed is refused rather than run past' \
        --version 2.0.0 --previous 1.0.0 --changelog "$unclosed"

    local body line
    body="$(body_of --version 2.0.0 --previous 1.0.0 --changelog "$changelog")"
    for line in '# raise the output level' 'ha audio volume output 100' \
        '- The bullet after the block is still part of this section.'; do
        if printf '%s\n' "$body" | grep -qF -- "$line"; then
            pass "the body still carries '$line'"
        else
            fail "the body still carries '$line'"
        fi
    done
}

check_the_released_section_leads() {
    step 'the released version has to be the topmost section in range'

    # What everything downstream rests on: the first heading is the version being released and
    # the rest are what it folded in. A section written to the bottom of the file instead of the
    # top -- an ordinary enough mistake -- would have the release announce itself as something it
    # also carries, in a body that reads as though it were meant.
    local changelog="$SCRATCH_ROOT/misordered.md"
    cat >"$changelog" <<'CHANGELOG'
# Changelog

## 1.0.0

The older one, written above the newer.

## 2.0.0

Appended to the bottom rather than the top.
CHANGELOG

    assert_refuses 1 'a changelog written oldest-first is refused, not quietly reordered' \
        --version 2.0.0 --previous '' --changelog "$changelog"
}

check_it_refuses_rather_than_publishing_nothing() {
    step 'what it refuses to build a body out of'

    # The case this whole script exists to make loud. A tag whose version nobody wrote up would
    # otherwise publish an empty release body and look deliberate.
    assert_refuses 1 'a version with no section is an error, not an empty body' \
        --version 9.9.9 --previous 0.1.8 --changelog "$REAL_CHANGELOG"

    assert_refuses 1 'a --previous at or above --version is refused' \
        --version 0.1.5 --previous 0.1.8 --changelog "$REAL_CHANGELOG"
    assert_refuses 1 'a --previous equal to --version is refused' \
        --version 0.1.8 --previous 0.1.8 --changelog "$REAL_CHANGELOG"

    assert_refuses 1 'a --version that is not MAJOR.MINOR.PATCH is refused' \
        --version v0.1.8 --previous 0.1.7 --changelog "$REAL_CHANGELOG"
    assert_refuses 1 'a --previous that is neither a version nor empty is refused' \
        --version 0.1.8 --previous v0.1.7 --changelog "$REAL_CHANGELOG"

    assert_refuses 1 'a changelog that does not exist is refused' \
        --version 0.1.8 --previous 0.1.7 --changelog "$SCRATCH_ROOT/nowhere.md"

    # The lead line appends `:$VERSION` and `:latest`, so a ref that arrived already tagged
    # would announce `repo:tag:version` -- an image nobody published.
    local status=0
    "$NOTES" --image "$IMAGE:0.1.8" --version 0.1.8 --previous 0.1.7 \
        --changelog "$REAL_CHANGELOG" >/dev/null 2>&1 || status=$?
    assert_equal 1 "$status" 'an --image that already carries a tag is refused'

    # Usage rather than an error: `--previous` left off entirely is a caller that never looked
    # the previous tag up, and quoting the whole changelog at it would hide that.
    assert_refuses 2 'a missing --previous is a usage error, not an open range' \
        --version 0.1.8 --changelog "$REAL_CHANGELOG"
    assert_refuses 2 'a missing --version is a usage error' \
        --previous 0.1.7 --changelog "$REAL_CHANGELOG"
    assert_refuses 2 'a flag left without its value is a usage error' \
        --version 0.1.8 --previous
    assert_refuses 2 'an unknown flag is a usage error' \
        --version 0.1.8 --previous 0.1.7 --notes-file /dev/null
}

main() {
    printf 'release notes: checking %s\n' "$NOTES"

    [ -x "$NOTES" ] || {
        printf 'release notes: %s is not executable\n' "$NOTES" >&2
        exit 1
    }

    SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-test.XXXXXX")"
    # shellcheck disable=SC2064  # the path is wanted as it is now, not at trap time.
    trap "rm -rf -- '$SCRATCH_ROOT'" EXIT

    check_the_shipped_changelog
    check_the_lead_line
    check_the_sections_are_verbatim
    check_versions_are_compared_as_numbers
    check_headings_bound_the_sections
    check_fenced_blocks_are_content
    check_the_released_section_leads
    check_it_refuses_rather_than_publishing_nothing

    if [ "$FAILURES" -ne 0 ]; then
        printf '\nrelease notes: %d check(s) failed\n' "$FAILURES" >&2
        exit 1
    fi
    printf '\nrelease notes: every check passed\n'
}

main
