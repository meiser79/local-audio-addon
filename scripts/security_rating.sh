#!/usr/bin/env bash
#
# Recomputes the Supervisor's security rating for the add-on manifest and fails unless it is
# still 5 -- on a rise as well as a drop.
#
# The score is `rating_security()` in supervisor/apps/utils.py, arithmetic over the manifest at
# install time. For this one it is 5, +1 for the AppArmor profile, -1 for host_network. Nothing
# else here would notice a key that costs a point: the manifest linter checks the schema rather
# than the posture, and the number only ever surfaces on the store card.
#
# Needs: bash and awk.
#
# Usage: scripts/security_rating.sh [APP_DIR]        (default: local_audio/)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

readonly EXPECTED_RATING=5

# The tuple in rating_security(), not the Capabilities enum: IPC_LOCK, SYS_NICE, SYS_RESOURCE
# and SYS_TIME cost nothing.
readonly DANGEROUS_CAPABILITIES='BPF CHECKPOINT_RESTORE DAC_READ_SEARCH NET_ADMIN NET_RAW
    PERFMON SYS_ADMIN SYS_MODULE SYS_PTRACE SYS_RAWIO'

APP_DIR="${1:-$SCRIPT_DIR/../local_audio}"
readonly APP_DIR
readonly CONFIG="$APP_DIR/config.yaml"

die() {
    printf '::error::security rating: %s\n' "$1" >&2
    exit 1
}

# Emits `S<TAB>key<TAB>value` per top-level scalar and `L<TAB>key<TAB>item` per top-level
# sequence item. Indentation is the whole of how nesting is handled, so `options:`'s own keys
# never reach the caller as top-level ones.
parse_manifest() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*(#|$)/ { next }

        /^[A-Za-z_][A-Za-z0-9_]*:/ {
            key = substr($0, 1, index($0, ":") - 1)
            print "S\t" key "\t" strip(substr($0, index($0, ":") + 1))
            next
        }

        /^[[:space:]]+-[[:space:]]*/ {
            sub(/^[[:space:]]+-[[:space:]]*/, "")
            print "L\t" key "\t" strip($0)
        }

        function strip(s) {
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
            return s
        }
    ' "$1"
}

# PyYAML silently keeps the last of a duplicate pair, so reading the first here would score a
# manifest the Supervisor scores differently. Neither value is safe to assume was meant.
reject_duplicate_keys() {
    local dupes
    dupes="$(printf '%s\n' "$MANIFEST" | awk -F '\t' '$1 == "S" { seen[$2]++ }
        END { for (k in seen) if (seen[k] > 1) printf "%s ", k }')"
    [ -z "$dupes" ] || die "set twice in $CONFIG: ${dupes% }"
}

manifest_scalar() {
    printf '%s\n' "$MANIFEST" | awk -F '\t' -v k="$1" '$1 == "S" && $2 == k { print $3; exit }'
}

manifest_has_key() {
    printf '%s\n' "$MANIFEST" | awk -F '\t' -v k="$1" '$1 == "S" && $2 == k { found = 1 }
        END { exit !found }'
}

# voluptuous' Boolean, which validates these keys, takes the YAML 1.1 spellings too. Anything
# else is rejected rather than defaulted: guessing `false` is how a costly key would pass.
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

# One capability per line, in either YAML sequence form.
manifest_privileged() {
    local raw items

    manifest_has_key privileged || return 0

    raw="$(manifest_scalar privileged)"
    if [ -n "$raw" ]; then
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

DERIVATION=()

term() {
    local delta=$1 why=$2
    RATING=$((RATING + delta))
    DERIVATION+=("$(printf '%+d  %s' "$delta" "$why")")
}

# Resolved up here rather than lazily inside the arithmetic: a `die` in a command substitution
# only kills the subshell, so a value read from inside `if [ "$(...)" ]` would come back empty
# and be scored as absent. These are plain assignments, so `set -e` carries the refusal out.
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

# In the order rating_security() computes it, so the two can be read side by side.
compute_rating() {
    RATING=5

    # The profile has to be installable, not merely enabled: install_apparmor() ships
    # apparmor.txt before the image is pulled, so a prebuilt image earns the point too.
    if [ "$APPARMOR_ENABLED" = false ]; then
        term -1 'apparmor: false'
    elif [ -f "$APP_DIR/apparmor.txt" ]; then
        term +1 'apparmor.txt ships a profile'
    fi

    if [ "$INGRESS" = true ]; then
        term +2 'ingress: true'
    elif [ "$AUTH_API" = true ]; then
        term +1 'auth_api: true'
    fi

    # No `signed` term: AppModel.signed is a hardcoded False, so it cannot fire for any add-on.

    # One branch, so four dangerous capabilities and kernel modules together still cost the
    # single point.
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

    # The pair is the term: the UTS namespace only lets a container rename the host if it also
    # holds CAP_SYS_ADMIN.
    if [ "$HOST_UTS" = true ] && has_capability SYS_ADMIN; then
        term -1 'host_uts: true alongside SYS_ADMIN'
    fi

    # Not a term but a verdict: either one pins the rating at the floor.
    if [ "$DOCKER_API" = true ] || [ "$FULL_ACCESS" = true ]; then
        RATING=1
        DERIVATION+=('=1  docker_api or full_access overrides every term above')
    fi

    if [ "$RATING" -gt 8 ]; then RATING=8; fi
    if [ "$RATING" -lt 1 ]; then RATING=1; fi
}

main() {
    [ -f "$CONFIG" ] || die "no manifest at $CONFIG"

    MANIFEST="$(parse_manifest "$CONFIG")"
    readonly MANIFEST

    reject_duplicate_keys
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
        die "the manifest now rates $RATING, not $EXPECTED_RATING -- if that is deliberate, move EXPECTED_RATING in this script with it"
    fi

    printf '\nsecurity rating: %d\n' "$RATING"
}

main
