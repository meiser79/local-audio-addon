#!/usr/bin/env bash
#
# Unit checks for scripts/security_rating.sh.
#
# A check that can only ever say "5" is a green light with no wiring behind it, and the one
# thing CI cannot demonstrate for itself is that the check would have gone red. So every
# rating-relevant key is flipped here in a scratch copy of the manifest and the derived number
# asserted against what rating_security() would return for it. The real manifest is only read.
#
# Needs: bash, awk and mktemp.
#
# Usage: scripts/security_rating_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
readonly CHECK="$SCRIPT_DIR/security_rating.sh"
readonly REAL_APP="$SCRIPT_DIR/../local_audio"

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

new_scratch() {
    local dir
    dir="$(mktemp -d "$SCRATCH_ROOT/app.XXXXXX")"
    cp "$REAL_APP/config.yaml" "$dir/config.yaml"
    cp "$REAL_APP/apparmor.txt" "$dir/apparmor.txt"
    printf '%s\n' "$dir"
}

# `error` when the check refused to read the manifest at all -- a distinct outcome from a
# number, so a parse failure is not mistaken for a rating.
rating_of() {
    local out=""
    if ! out="$("$CHECK" "$1" 2>&1)"; then :; fi
    printf '%s\n' "$out" |
        awk '$1 == "rating" { print $2; found = 1 } END { if (!found) print "error" }'
}

exits_red() {
    if "$CHECK" "$1" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# The exit status is what CI rides on, so it is asserted alongside the number: a check that
# printed 3 and exited 0 would sail through the lint job.
assert_rating() {
    local dir=$1 want=$2 what=$3 got
    got="$(rating_of "$dir")"
    assert_equal "$want" "$got" "$what"

    if [ "$want" = 5 ]; then
        if exits_red "$dir"; then
            fail "$what -- rated 5 but the check still exited non-zero"
        fi
    elif ! exits_red "$dir"; then
        fail "$what -- rated $got but the check exited 0"
    fi
}

check_the_shipped_manifest() {
    step 'the manifest as it stands'

    assert_rating "$REAL_APP" 5 'local_audio rates 5'

    local dir
    dir="$(new_scratch)"
    rm "$dir/apparmor.txt"
    assert_rating "$dir" 4 'without apparmor.txt the profile point is gone'
}

check_the_costly_keys() {
    step 'keys that cost a point'

    local dir

    dir="$(new_scratch)"
    printf 'host_pid: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 3 'host_pid: true costs two'

    # The manifest sets neither half of the pair, so both are added here. With host_uts
    # SYS_ADMIN costs twice, once as a capability and once for the pair; without it only the
    # capability point -- which is what proves the pair is read as a pair rather than as either
    # half.
    dir="$(new_scratch)"
    printf 'host_uts: true\nprivileged:\n  - SYS_ADMIN\n' >>"$dir/config.yaml"
    assert_rating "$dir" 3 'SYS_ADMIN alongside host_uts costs two'

    dir="$(new_scratch)"
    printf 'privileged:\n  - SYS_ADMIN\n' >>"$dir/config.yaml"
    assert_rating "$dir" 4 'SYS_ADMIN without host_uts costs one'

    dir="$(new_scratch)"
    printf 'apparmor: false\n' >>"$dir/config.yaml"
    assert_rating "$dir" 3 'apparmor: false turns the +1 into a -1'

    dir="$(new_scratch)"
    printf 'kernel_modules: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 4 'kernel_modules: true costs one'

    dir="$(new_scratch)"
    printf 'hassio_role: manager\n' >>"$dir/config.yaml"
    assert_rating "$dir" 4 'hassio_role: manager costs one'

    dir="$(new_scratch)"
    printf 'hassio_role: admin\n' >>"$dir/config.yaml"
    assert_rating "$dir" 3 'hassio_role: admin costs two'

    dir="$(new_scratch)"
    printf 'docker_api: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 1 'docker_api: true drops it to the floor'

    dir="$(new_scratch)"
    printf 'full_access: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 1 'full_access: true drops it to the floor'
}

check_the_earning_keys() {
    step 'keys that would raise it'

    local dir

    dir="$(new_scratch)"
    printf 'ingress: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 7 'ingress: true would earn two'

    dir="$(new_scratch)"
    printf 'auth_api: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 6 'auth_api: true would earn one'

    dir="$(new_scratch)"
    sed -i 's/^host_network: true$/host_network: false/' "$dir/config.yaml"
    assert_rating "$dir" 6 'dropping host_network would earn one'

    dir="$(new_scratch)"
    printf 'ingress: true\nauth_api: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 7 'ingress and auth_api together still earn only two'

    if ! exits_red "$dir"; then
        fail 'a rating above 5 turns the check red'
    else
        pass 'a rating above 5 turns the check red'
    fi
}

check_the_free_keys() {
    step 'keys that move nothing'

    local dir

    dir="$(new_scratch)"
    printf 'privileged:\n  - SYS_NICE\n' >>"$dir/config.yaml"
    assert_rating "$dir" 5 'a capability outside the costly ten is free'

    dir="$(new_scratch)"
    printf 'privileged: [SYS_NICE, SYS_ADMIN]\n' >>"$dir/config.yaml"
    assert_rating "$dir" 4 'a flow sequence is read the same as a block one'

    dir="$(new_scratch)"
    printf 'host_ipc: true\nvideo: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 5 'keys the rating does not read leave it alone'
}

check_nesting_is_not_flattened() {
    step 'nested keys are not top-level ones'

    # The failure mode of every line-oriented YAML reader: an option named `host_pid` inside
    # `options:` is a string the user types, not a namespace the add-on runs in.
    local dir
    dir="$(new_scratch)"
    printf 'somewhere_nested:\n  host_pid: true\n  full_access: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 5 'an indented host_pid is not the host_pid the rating reads'
}

check_it_refuses_to_guess() {
    step 'values it cannot read are an error, not a default'

    local dir

    dir="$(new_scratch)"
    printf 'host_pid: perhaps\n' >>"$dir/config.yaml"
    assert_rating "$dir" error 'a non-boolean where a boolean belongs is rejected'

    dir="$(new_scratch)"
    printf 'hassio_role: superuser\n' >>"$dir/config.yaml"
    assert_rating "$dir" error 'a role the Supervisor does not have is rejected'

    dir="$(new_scratch)"
    printf 'privileged: SYS_ADMIN\n' >>"$dir/config.yaml"
    assert_rating "$dir" error 'a bare scalar where a sequence belongs is rejected'

    dir="$(new_scratch)"
    rm "$dir/config.yaml"
    assert_rating "$dir" error 'a missing manifest is rejected'

    # PyYAML keeps the last of a duplicate pair, so reading the first would call this 5 while
    # the Supervisor installed it at 3.
    dir="$(new_scratch)"
    printf 'host_pid: false\nhost_pid: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" error 'a key set twice is rejected rather than resolved'
}

check_comments_and_quotes() {
    step 'comments and quoting'

    local dir

    dir="$(new_scratch)"
    printf 'host_pid: true  # for the profiler\n' >>"$dir/config.yaml"
    assert_rating "$dir" 3 'an inline comment does not hide the value'

    dir="$(new_scratch)"
    printf 'hassio_role: "admin"\n' >>"$dir/config.yaml"
    assert_rating "$dir" 3 'a quoted value is read unquoted'

    # config.yaml carries prose above every setting, so a reader that matched inside comments
    # would misread the file as it stands.
    dir="$(new_scratch)"
    printf '# host_pid: true\n#full_access: true\n' >>"$dir/config.yaml"
    assert_rating "$dir" 5 'a commented-out key is not set'
}

main() {
    printf 'security rating: checking %s\n' "$CHECK"

    [ -x "$CHECK" ] || {
        printf 'security rating: %s is not executable\n' "$CHECK" >&2
        exit 1
    }

    SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/security-rating-test.XXXXXX")"
    # shellcheck disable=SC2064  # the path is wanted as it is now, not at trap time.
    trap "rm -rf -- '$SCRATCH_ROOT'" EXIT

    check_the_shipped_manifest
    check_the_costly_keys
    check_the_earning_keys
    check_the_free_keys
    check_nesting_is_not_flattened
    check_it_refuses_to_guess
    check_comments_and_quotes

    if [ "$FAILURES" -ne 0 ]; then
        printf '\nsecurity rating: %d check(s) failed\n' "$FAILURES" >&2
        exit 1
    fi
    printf '\nsecurity rating: every check passed\n'
}

main
