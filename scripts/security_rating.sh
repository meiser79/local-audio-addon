#!/usr/bin/env bash
#
# Recomputes the Supervisor's security rating for the app manifest and fails unless it is still
# 5.
#
# The number the store card shows is `rating_security()` in supervisor/apps/utils.py, computed
# from the manifest at install time. Nothing in this repository would otherwise notice a key
# growing in config.yaml that costs a point -- the manifest linter checks the schema, not the
# posture, and the card is the only place the score is ever displayed. README.md's `## Security
# rating` section carries the arithmetic and why 5 is the ceiling; this asserts it.
#
# It fails in both directions on purpose. A drop is a regression; a rise means the write-up went
# stale, and a rating nobody documented is the same blind spot in the other direction.
#
# The parser is deliberately strict: a rating-relevant key whose value it cannot read is an
# error, never a default. Guessing `false` for something it did not understand would turn a
# manifest that costs points into a green check.
#
# Needs: bash and awk. No docker, no image, no Supervisor.
#
# Usage: scripts/security_rating.sh [APP_DIR]        (default: local_audio/)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

readonly EXPECTED_RATING=5

# The capabilities that cost a point. Not every capability the Supervisor accepts is here --
# IPC_LOCK, SYS_NICE, SYS_RESOURCE and SYS_TIME are free -- so this is a copy of the tuple in
# rating_security(), not of the Capabilities enum.
readonly DANGEROUS_CAPABILITIES='BPF CHECKPOINT_RESTORE DAC_READ_SEARCH NET_ADMIN NET_RAW
    PERFMON SYS_ADMIN SYS_MODULE SYS_PTRACE SYS_RAWIO'

APP_DIR="${1:-$SCRIPT_DIR/../local_audio}"
readonly APP_DIR
readonly CONFIG="$APP_DIR/config.yaml"

die() {
    printf '::error::security rating: %s\n' "$1" >&2
    exit 1
}

# ==============================================================================
# Reading the manifest
# ==============================================================================

# A top-level-only reader for the subset of YAML an app manifest is written in. Emits one
# `S<TAB>key<TAB>value` line per top-level scalar and one `L<TAB>key<TAB>item` line per item of a
# top-level block or flow sequence.
#
# Indentation is the whole of how nesting is handled: anything indented belongs to the last
# column-0 key, so `options:`'s own `name:` never reaches the caller as a top-level `name`. That
# also covers the folded `description: >-` block, whose prose lines are children of a key
# nothing here reads.
parse_manifest() {
    awk '
        { sub(/\r$/, "") }

        # Comment or blank at any depth: not a key, and not the end of the block it sits in.
        /^[[:space:]]*(#|$)/ { next }

        /^[A-Za-z_][A-Za-z0-9_]*:/ {
            key = substr($0, 1, index($0, ":") - 1)
            value = substr($0, index($0, ":") + 1)
            print "S\t" key "\t" strip(value)
            next
        }

        # Indented, so a child of the key above. Only sequence items are passed on; a nested
        # mapping (`schema:`, `options:`) has no rating-relevant shape.
        /^[[:space:]]+-[[:space:]]*/ {
            sub(/^[[:space:]]+-[[:space:]]*/, "")
            print "L\t" key "\t" strip($0)
        }

        function strip(s) {
            # An inline comment needs whitespace before the # to be one, which is what keeps a
            # value that legitimately contains a hash intact.
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            # Quotes are stripped as a pair only, so a value with one stray quote stays odd
            # enough for the callers below to reject.
            if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
            return s
        }
    ' "$1"
}

# The raw value of a top-level key, or the empty string when the manifest does not set it.
manifest_scalar() {
    printf '%s\n' "$MANIFEST" | awk -F '\t' -v k="$1" '$1 == "S" && $2 == k { print $3; exit }'
}

manifest_has_key() {
    printf '%s\n' "$MANIFEST" | awk -F '\t' -v k="$1" '$1 == "S" && $2 == k { found = 1 }
        END { exit !found }'
}

# ==============================================================================
# Typing the values the rating reads
# ==============================================================================

# voluptuous' Boolean, which is what the Supervisor validates these keys with, takes the YAML
# 1.1 spellings as well as true/false. Anything else is rejected rather than defaulted.
manifest_bool() {
    local key=$1 default=$2 raw

    manifest_has_key "$key" || {
        printf '%s\n' "$default"
        return
    }

    raw="$(manifest_scalar "$key")"
    case ${raw,,} in
        true | yes | on | enable | 1) printf 'true\n' ;;
        false | no | off | disable | 0) printf 'false\n' ;;
        *) die "$key is '$raw', which is not a boolean the Supervisor would accept" ;;
    esac
}

# `privileged` is a list of Capabilities, in either YAML sequence form. Emits one capability per
# line, upper-cased the way the enum spells them.
manifest_privileged() {
    local raw items

    manifest_has_key privileged || return 0

    raw="$(manifest_scalar privileged)"
    if [ -n "$raw" ]; then
        # Flow sequence on the key's own line.
        case $raw in
            \[*\]) ;;
            *) die "privileged is '$raw', which is neither a block nor a flow sequence" ;;
        esac
        items="${raw#\[}"
        items="${items%\]}"
        printf '%s\n' "${items//,/$'\n'}" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$|["'"'"']/, "")
            if (length($0)) print toupper($0) }'
        return 0
    fi

    printf '%s\n' "$MANIFEST" |
        awk -F '\t' '$1 == "L" && $2 == "privileged" { print toupper($3) }'
}

has_capability() {
    printf '%s\n' "$PRIVILEGED" | grep -qx -- "$1"
}

# ==============================================================================
# rating_security(), as the Supervisor computes it
# ==============================================================================

# Kept in the order and the wording of supervisor/apps/utils.py, so the two can be read side by
# side when the algorithm moves. `explain` records every term that fired; a failure prints the
# whole derivation rather than just the number it disagreed with.
DERIVATION=()

term() {
    local delta=$1 why=$2
    RATING=$((RATING + delta))
    DERIVATION+=("$(printf '%+d  %s' "$delta" "$why")")
}

# Every value the rating reads, resolved in one pass up here rather than lazily inside the
# arithmetic below. A `die` in a command substitution only kills the subshell, so a value read
# from inside an `if [ "$(...)" ]` would come back empty and be scored as absent -- the exact
# guess the parser is written not to make. These are plain assignments, so `set -e` carries the
# refusal out.
read_manifest_values() {
    APPARMOR_ENABLED="$(manifest_bool apparmor true)"
    INGRESS="$(manifest_bool ingress false)"
    AUTH_API="$(manifest_bool auth_api false)"
    KERNEL_MODULES="$(manifest_bool kernel_modules false)"
    HOST_NETWORK="$(manifest_bool host_network false)"
    HOST_PID="$(manifest_bool host_pid false)"
    HOST_UTS="$(manifest_bool host_uts false)"
    DOCKER_API="$(manifest_bool docker_api false)"
    FULL_ACCESS="$(manifest_bool full_access false)"
    HASSIO_ROLE="$(manifest_role)"
    PRIVILEGED="$(manifest_privileged)"
}

compute_rating() {
    RATING=5

    # AppArmor. `apparmor: false` disables it outright; otherwise the profile counts only once
    # the Supervisor has one installed for the slug, which is what shipping apparmor.txt beside
    # the manifest gets you -- install_apparmor() runs before the image pull, so a prebuilt
    # image earns it the same as a built one.
    if [ "$APPARMOR_ENABLED" = false ]; then
        term -1 'apparmor: false'
    elif [ -f "$APP_DIR/apparmor.txt" ]; then
        term +1 'apparmor.txt ships a profile'
    fi

    # Home Assistant login & ingress -- one or the other, never both.
    if [ "$INGRESS" = true ]; then
        term +2 'ingress: true'
    elif [ "$AUTH_API" = true ]; then
        term +1 'auth_api: true'
    fi

    # Signed. AppModel.signed is a hardcoded False -- "Currently no signing support" -- so this
    # term cannot fire for any app, and is here only to be visibly zero.

    # Privileged options. One branch, so a manifest that grants four dangerous capabilities and
    # mounts kernel modules still loses the single point -- which is why the reason is reported
    # as a list rather than as whichever term happened to fire first.
    local reasons=()
    local cap
    for cap in $DANGEROUS_CAPABILITIES; do
        if has_capability "$cap"; then
            reasons+=("privileged grants $cap")
        fi
    done
    if [ "$KERNEL_MODULES" = true ]; then
        reasons+=('kernel_modules: true')
    fi
    if [ "${#reasons[@]}" -ne 0 ]; then
        term -1 "$(
            IFS=', '
            printf '%s' "${reasons[*]}"
        )"
    fi

    # Supervisor API role.
    case "$HASSIO_ROLE" in
        manager) term -1 'hassio_role: manager' ;;
        admin) term -2 'hassio_role: admin' ;;
    esac

    if [ "$HOST_NETWORK" = true ]; then
        term -1 'host_network: true'
    fi
    if [ "$HOST_PID" = true ]; then
        term -2 'host_pid: true'
    fi

    # The UTS namespace is free on its own: renaming the host through it needs CAP_SYS_ADMIN,
    # so the pair is what costs a point.
    if [ "$HOST_UTS" = true ] && has_capability SYS_ADMIN; then
        term -1 'host_uts: true alongside SYS_ADMIN'
    fi

    # Docker API access and full hardware access are not a term but a verdict: either one pins
    # the rating at the floor whatever else the manifest says.
    if [ "$DOCKER_API" = true ] || [ "$FULL_ACCESS" = true ]; then
        RATING=1
        DERIVATION+=('=1  docker_api or full_access overrides every term above')
    fi

    # Clamped into 1-8 last, exactly as the Supervisor does.
    if [ "$RATING" -gt 8 ]; then RATING=8; fi
    if [ "$RATING" -lt 1 ]; then RATING=1; fi
}

manifest_role() {
    local raw
    manifest_has_key hassio_role || {
        printf 'default\n'
        return
    }
    raw="$(manifest_scalar hassio_role)"
    case ${raw,,} in
        default | homeassistant | backup | manager | admin) printf '%s\n' "${raw,,}" ;;
        *) die "hassio_role is '$raw', which is not one of the Supervisor's roles" ;;
    esac
}

# ==============================================================================

main() {
    [ -f "$CONFIG" ] || die "no manifest at $CONFIG"

    MANIFEST="$(parse_manifest "$CONFIG")"
    readonly MANIFEST

    read_manifest_values
    compute_rating

    printf 'security rating: %s\n' "$CONFIG"
    printf '  base                5\n'
    local line
    for line in "${DERIVATION[@]}"; do
        printf '  %s\n' "$line"
    done
    printf '  rating              %d\n' "$RATING"

    if [ "$RATING" -ne "$EXPECTED_RATING" ]; then
        die "the manifest now rates $RATING, not $EXPECTED_RATING -- if that is deliberate, update README.md's '## Security rating' section and EXPECTED_RATING in this script together"
    fi

    printf '\nsecurity rating: %d, as documented\n' "$RATING"
}

main
