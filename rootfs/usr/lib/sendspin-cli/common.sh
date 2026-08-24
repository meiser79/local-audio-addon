# shellcheck shell=bash
# Paths, option reading and the bundled-daemon decision, shared by the s6
# services and the container health check.

readonly SENDSPIN_RUN_DIR=/run/sendspin-cli
readonly SENDSPIN_CONF=/run/sendspin-cli/sendspin-cli.conf
readonly SENDSPIN_STATE_DIR=/data/state
readonly SENDSPIN_CONTROL_SOCKET=/run/sendspin-cli/control.sock
readonly SENDSPIN_DAEMON_DECISION=/run/sendspin-cli/bundled-daemons
readonly SYSTEM_BUS_DIR=/var/run/dbus
readonly SYSTEM_BUS_SOCKET=/var/run/dbus/system_bus_socket
readonly AVAHI_SOCKET=/run/avahi-daemon/socket
readonly PULSE_SOCKET=/run/audio/pulse.sock
readonly PULSE_CLIENT_CONF=/etc/pulse/client.conf

sendspin::log() {
    printf '%s\n' "$*" >&2
}

# Populate SENDSPIN_NAME, SENDSPIN_OUTPUT, SENDSPIN_LOG_LEVEL and
# SENDSPIN_SERVER. Only the source differs between an add-on and a plain
# container; the defaults below are applied to both so the two cannot drift.
sendspin::read_options() {
    local config name value

    # SUPERVISOR_TOKEN is injected by the Supervisor, and it is what bashio
    # needs: bashio reads the options from the Supervisor API, not from
    # /data/options.json.
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        source /usr/lib/bashio/bashio.sh

        # One fetch, so that an unreachable Supervisor stops the container
        # rather than letting every key fall through to a default below.
        config=$(bashio::addon.config) \
            || bashio::exit.nok 'Could not read the add-on options from the Supervisor.'

        SENDSPIN_NAME=$(sendspin::option "${config}" 'name')
        # Not settable from the add-on any more: absent from the Supervisor's
        # config it falls through to the default below. The read stays so the
        # stand-in Supervisor in scripts/smoke_test.sh can still deliver one.
        SENDSPIN_OUTPUT=$(sendspin::option "${config}" 'output')
        SENDSPIN_LOG_LEVEL=$(sendspin::option "${config}" 'log_level')
        SENDSPIN_SERVER=$(sendspin::option "${config}" 'server')
    fi

    # Under host_network the container's hostname is the Home Assistant host's,
    # which is the name a user expects to see. Reading it directly avoids the
    # hassio_api grant that bashio::info would need for the same answer.
    : "${SENDSPIN_NAME:=$(hostname)}"
    : "${SENDSPIN_OUTPUT:=default}"
    : "${SENDSPIN_LOG_LEVEL:=info}"
    SENDSPIN_SERVER="${SENDSPIN_SERVER:-}"

    # A newline in a value would add config keys of the caller's choosing, and
    # an injected `server` turns the mDNS advertisement off without saying so.
    for name in SENDSPIN_NAME SENDSPIN_OUTPUT SENDSPIN_LOG_LEVEL SENDSPIN_SERVER; do
        value="${!name}"
        if [ "${value}" != "${value%%$'\n'*}" ]; then
            sendspin::log "${name} contains a newline, which would inject configuration keys."
            exit 1
        fi
    done
}

# Whether this container runs its own dbus and avahi-daemon, recorded once by
# the sendspin-init oneshot before any of them start. The answer comes from
# configuration alone: a runtime reachability probe is not used because both of
# its wrong answers are silent, giving either two responders competing on port
# 5353 or a player that runs but is never discovered.
sendspin::decide_daemons() {
    sendspin::read_options

    mkdir -p "${SENDSPIN_RUN_DIR}"

    if [ -S "${SYSTEM_BUS_SOCKET}" ]; then
        printf 'no\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log "Host D-Bus socket present at ${SYSTEM_BUS_SOCKET}: advertising through the host's Avahi, the bundled dbus and avahi-daemon stay down."
    elif [ -n "${SENDSPIN_SERVER}" ] && ! sendspin::server_is_mdns "${SENDSPIN_SERVER}"; then
        printf 'no\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log 'A fixed server is configured, which suppresses the mDNS advertisement: the bundled dbus and avahi-daemon stay down.'
    elif [ -n "${SENDSPIN_SERVER}" ]; then
        printf 'yes\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log 'Starting the bundled dbus and avahi-daemon: the mdns: server value needs mDNS to resolve the server.'
    else
        printf 'yes\n' > "${SENDSPIN_DAEMON_DECISION}"
        sendspin::log 'Starting the bundled dbus and avahi-daemon to advertise this player over mDNS.'
    fi
}

# The decision the oneshot recorded, as `yes` or `no`. Callers assign it to a
# variable rather than testing this in a condition, because errexit is
# suspended inside a condition and an absent file -- the oneshot never
# finished -- would then read as a quiet "no".
sendspin::daemon_decision() {
    cat "${SENDSPIN_DAEMON_DECISION}"
}

# s6-rc guarantees only that a dependency has been started, not that it is
# listening. The D-Bus wait is load-bearing: avahi-daemon exits without a bus
# and would be restarted until it won the race. The Avahi wait is not, since
# the player retries its registration anyway; it is there to keep a failed
# first attempt out of the log. Avahi is reached over D-Bus, so its socket is
# a stand-in for "avahi finished starting" rather than the player's own path
# to it. Either wait running out is survivable, so both return 0.
sendspin::wait_for_socket() {
    local i

    for ((i = 0; i < 100; i++)); do
        if [ -S "$1" ]; then
            break
        fi
        sleep 0.1
    done

    return 0
}

# An unset option reads as an empty string. bashio::config is not used for the
# read because it cannot tell the JSON null of an unset option from the string
# "null", which is a valid value for output.
sendspin::option() {
    jq -r --arg key "$2" '.[$key] // empty' <<< "$1"
}

# The mdns: prefix is reserved before the first colon in upstream's -s grammar;
# everything else is a host, host:port or ws URL.
sendspin::server_is_mdns() {
    [ "${1#mdns:}" != "$1" ]
}

# A server value may carry userinfo, and the connection-mode line is the first
# thing that gets pasted into a support issue.
sendspin::redact_server() {
    printf '%s\n' "$1" | sed -e 's|://[^/@]*@|://|' -e 's|^[^:/@]*:[^/@]*@||'
}

# ==============================================================================
# The silent-output check
#
# Home Assistant's PulseAudio sink is shared state: every add-on plays through
# it, module-device-restore makes a level set once survive reboots, and the
# player applies Music Assistant's volume as software gain over the PCM rather
# than through a mixer. A sink another add-on left at zero, or muted, is
# therefore silence at every position of the slider, and nothing in Music
# Assistant can say so. Reported at start, never corrected: the level belongs to
# the user's Audio panel, and raising it here would override a deliberately low
# setting on every restart and every update.
# ==============================================================================

# Bounded, and pinned to the socket the caller has already found, so a
# PulseAudio that is up but not answering costs three seconds rather than the
# oneshot's whole 30s timeout-up. LC_ALL=C because pactl's output is translated
# and the keys parsed below are translated with it.
sendspin::pactl() {
    LC_ALL=C PULSE_SERVER="unix:${PULSE_SOCKET}" timeout 3 pactl "$@" 2> /dev/null
}

# `default-sink` from a PulseAudio client.conf on stdin, or nothing. The
# Supervisor renders that file per add-on from the Audio panel selection and
# bind-mounts it in, so this key is the device a user picked. Last assignment
# wins, as it does for PulseAudio itself.
sendspin::pulse_conf_default_sink() {
    awk '
        /^[[:space:]]*[;#]/ { next }
        /^[[:space:]]*default-sink[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            value = $0
        }
        END { if (value != "") print value }
    '
}

# The daemon's own default sink, from `pactl info` on stdin. Only a fallback:
# the ALSA pulse plugin connects its stream with a NULL device and libpulse
# substitutes the *client* default, so client.conf is the answer whenever it
# carries one.
sendspin::pulse_info_default_sink() {
    sed -n 's/^Default Sink:[[:space:]]*//p' | tail -n 1
}

# Index, name, description, mute and level of the sink named "$1", one field
# per line, from `pactl list sinks` on stdin. Prints nothing at all unless the
# sink is there and every field parsed, so a pactl whose format has moved reads
# as "no answer" rather than as a healthy output.
sendspin::pulse_sink_state() {
    awk -v target="$1" '
        # Sink fields are indented one tab; the properties and ports below them
        # are indented further, which is what keeps them out of these matches.
        function value(line) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            return line
        }

        # A per-channel line: `front-left: 32768 /  74% / -7.85 dB, ...`. The
        # loudest channel decides, so a sink is silent only when every channel
        # is. An empty return means no percentage was found at all.
        function loudest(line,   best, pct) {
            best = ""
            while (match(line, /[0-9]+%/)) {
                pct = substr(line, RSTART, RLENGTH - 1) + 0
                if (best == "" || pct > best) best = pct
                line = substr(line, RSTART + RLENGTH)
            }
            return best
        }

        function emit() {
            if (!done && name == target \
                && idx != "" && description != "" && mute != "" && level != "") {
                print idx; print name; print description; print mute; print level
                done = 1
            }
        }

        /^Sink #/ {
            emit()
            idx = ""; name = ""; description = ""; mute = ""; level = ""
            if (match($0, /[0-9]+/)) idx = substr($0, RSTART, RLENGTH)
            next
        }
        /^\tName:/        { name = value($0); next }
        /^\tDescription:/ { description = value($0); next }
        /^\tMute:/        { mute = value($0); next }
        # `Base Volume:` is the hardware reference level and is not this; it
        # does not match because the key here starts right after the tab.
        /^\tVolume:/      { level = loudest($0); next }

        END { emit() }
    '
}

# The warning itself, given a sink's state. Says nothing for an audible sink:
# a healthy start has to be indistinguishable from one where the check never
# ran. Separate from the reading above so both are exercised by
# scripts/pactl_parse_test.sh.
sendspin::warn_if_sink_is_silent() {
    local idx=$1 name=$2 description=$3 mute=$4 level=$5
    local state

    case ${level} in
        '' | *[!0-9]*) return 0 ;;
    esac

    if [ "${mute}" = yes ] && [ "${level}" -eq 0 ]; then
        state='muted and turned down to zero'
    elif [ "${mute}" = yes ]; then
        state='muted'
    elif [ "${level}" -eq 0 ]; then
        state='turned down to zero'
    else
        return 0
    fi

    sendspin::log "The Home Assistant audio output this player plays through is ${state}, so nothing it plays will be heard."
    sendspin::log "That output is sink #${idx}, ${name} (${description})."
    sendspin::log 'Music Assistant volume cannot raise it: that is applied to the audio this player sends, not to the output it sends to.'
    sendspin::log 'Raise it from the Home Assistant host console, or a terminal add-on:'
    sendspin::log "    ha audio volume output --index ${idx} --unmute"
    sendspin::log "    ha audio volume output --index ${idx} --volume 85"
    sendspin::log 'The level is shared with every other add-on on this machine, which is why this one will not set it for you.'
}

# Read the selected output's state and warn if it is silent. Advisory only, so
# every path here returns success: the oneshot runs under `set -euo pipefail`
# with a 30s budget, and a PulseAudio that cannot be reached must be a shrug in
# the log rather than a container that never starts.
sendspin::check_output_is_audible() {
    local sinks info target state
    local -a field

    # Compose has no PulseAudio at all -- `default` is ALSA's own default over
    # /dev/snd -- so there is no sink to have an opinion about. Silence here is
    # the whole behaviour, not a fallback.
    [ -S "${PULSE_SOCKET}" ] || return 0

    sinks=$(sendspin::pactl list sinks) || return 0
    [ -n "${sinks}" ] || return 0

    target=''
    if [ -r "${PULSE_CLIENT_CONF}" ]; then
        target=$(sendspin::pulse_conf_default_sink < "${PULSE_CLIENT_CONF}") || return 0
    fi
    if [ -z "${target}" ]; then
        info=$(sendspin::pactl info) || return 0
        target=$(sendspin::pulse_info_default_sink <<< "${info}") || return 0
    fi
    [ -n "${target}" ] || return 0

    state=$(sendspin::pulse_sink_state "${target}" <<< "${sinks}") || return 0
    [ -n "${state}" ] || return 0

    mapfile -t field <<< "${state}"
    [ "${#field[@]}" -eq 5 ] || return 0

    sendspin::warn_if_sink_is_silent \
        "${field[0]}" "${field[1]}" "${field[2]}" "${field[3]}" "${field[4]}"
}
