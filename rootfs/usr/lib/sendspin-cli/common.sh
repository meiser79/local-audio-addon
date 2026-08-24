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
# The player applies Music Assistant's volume as software gain and opens no
# mixer, so every reason its audio might not be heard lives in the PulseAudio
# sink it plays to and nothing in the player can see any of them: a sink another
# add-on left at zero, a sink routed to a port with nothing plugged into it, a
# sink that is not there at all. This block reads that sink once at start and
# says what it found. Reported, never corrected: the level and the port are the
# Audio panel's, and writing either would override a deliberate choice on every
# start.
# ==============================================================================

# Bounded, so a PulseAudio that is up but not answering costs three seconds
# rather than the oneshot's whole 30s timeout-up. LC_ALL=C because pactl's
# output is translated, and the keys parsed below with it.
sendspin::pactl() {
    LC_ALL=C PULSE_SERVER="unix:${PULSE_SOCKET}" timeout 3 pactl "$@" 2> /dev/null
}

# `default-sink` from a client.conf on stdin. The Supervisor renders that file
# per add-on from the Audio panel selection, so this key is the device the user
# picked. Last assignment wins, as it does for PulseAudio itself.
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

# The daemon's default sink, from `pactl info` on stdin. Only a fallback: the
# ALSA pulse plugin connects with a NULL device and libpulse then substitutes
# the *client* default, so client.conf wins whenever it carries one.
sendspin::pulse_info_default_sink() {
    sed -n 's/^Default Sink:[[:space:]]*//p' | tail -n 1
}

# Every sink name in `pactl list sinks` on stdin, one per line. Used only when
# a sink could not be read: whether the name is in here is what tells a wrong
# Audio panel selection apart from output this code could not parse, and the
# list itself is what the reader picks a replacement from.
sendspin::pulse_sink_names() {
    awk '
        /^\tName:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
        }
    '
}

# Index, name, description, mute, level, and then the active port's id,
# description and availability for the sink named "$1", one field per line, from
# `pactl list sinks` on stdin. Prints nothing unless the first five parsed, so a
# pactl whose format has moved reads as "no answer" rather than as a healthy
# sink.
#
# The three port fields are deliberately outside that guard: a sink with no
# `Ports:` block at all is legitimate -- a null sink has none -- and folding
# them in would turn the mute and level warning off for those sinks. They come
# back empty instead, which the caller reads as "could not tell".
sendspin::pulse_sink_state() {
    awk -v target="$1" '
        function value(line) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            return line
        }

        # The loudest channel decides: a sink is silent only when every channel
        # of it is, and one quiet channel is a balance setting. Empty means no
        # percentage was there to read.
        function loudest(line,   best, pct) {
            best = ""
            while (match(line, /[0-9]+%/)) {
                pct = substr(line, RSTART, RLENGTH - 1) + 0
                if (best == "" || pct > best) best = pct
                line = substr(line, RSTART + RLENGTH)
            }
            return best
        }

        # The last `(` on the line, so a port whose own description carries
        # brackets -- `Headphones (unplugged)` -- keeps them and the trailing
        # `(type: ..., priority: ..., not available)` is still the part read.
        function last_bracket(s,   i, at) {
            at = 0
            for (i = 1; i <= length(s); i++)
                if (substr(s, i, 1) == "(") at = i
            return at
        }

        # `\t\t<id>: <description> (<...>, <availability>)`. Both pactl shapes
        # end the bracket with the availability, whether or not `type:` and
        # `availability group:` are in front of it, so the last comma-separated
        # part of it is the answer in either.
        function port_line(line,   at, id, rest, bracket, n, part) {
            sub(/^\t\t/, "", line)
            sub(/[[:space:]]+$/, "", line)
            at = index(line, ":")
            if (at == 0) return
            id = substr(line, 1, at - 1)
            rest = substr(line, at + 1)
            sub(/^[[:space:]]+/, "", rest)

            port_description[block, id] = rest
            port_availability[block, id] = ""

            if (rest !~ /\)$/) return
            at = last_bracket(rest)
            if (at == 0) return

            bracket = substr(rest, at + 1, length(rest) - at - 1)
            rest = substr(rest, 1, at - 1)
            sub(/[[:space:]]+$/, "", rest)
            n = split(bracket, part, ",")
            sub(/^[[:space:]]+/, "", part[n])
            sub(/[[:space:]]+$/, "", part[n])

            port_description[block, id] = rest
            port_availability[block, id] = part[n]
        }

        function emit(   description, availability) {
            if (done || name != target \
                || idx == "" || sink_description == "" || mute == "" || level == "")
                return
            description = ""
            availability = ""
            if (port != "") {
                description = port_description[block, port]
                availability = port_availability[block, port]
            }
            print idx; print name; print sink_description; print mute; print level
            print port; print description; print availability
            done = 1
        }

        /^Sink #/ {
            emit()
            # Ports accumulate under a per-sink key rather than being cleared,
            # because whole-array `delete` is not in every awk this may meet.
            block++
            idx = ""; name = ""; sink_description = ""; mute = ""; level = ""
            port = ""; in_ports = 0
            if (match($0, /[0-9]+/)) idx = substr($0, RSTART, RLENGTH)
            next
        }
        # The `Ports:` block runs until the next key at one tab. Tracking it is
        # what keeps `Properties:` and `Formats:`, indented the same, out.
        /^\tPorts:/  { in_ports = 1; next }
        /^\t[^\t]/   { in_ports = 0 }
        # One tab exactly: properties and ports are indented further, and
        # `Base Volume:` -- the hardware reference level -- does not start its
        # key at the tab.
        /^\tName:/        { name = value($0); next }
        /^\tDescription:/ { sink_description = value($0); next }
        /^\tMute:/        { mute = value($0); next }
        /^\tVolume:/      { level = loudest($0); next }
        /^\tActive Port:/ { port = value($0); next }

        in_ports && /^\t\t[^\t]/ { port_line($0); next }

        END { emit() }
    '
}

# Says nothing for an audible sink: naming the output on a healthy start is
# sendspin::report_output's job, and this one only speaks up about the states
# below. Kept apart from the reading so that scripts/pactl_parse_test.sh can
# exercise both.
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

# The sink is fine but it is routed at a socket with nothing in it, which reads
# from the player exactly like a sink at zero.
#
# Only the literal `not available` may warn. PulseAudio also reports
# `availability unknown`, and that is what a card with no jack detection says
# about every one of its ports -- most line-outs. A warning on a working desktop
# line-out would be worse than the silence this exists to explain, so anything
# else, an unrecognised string included, says nothing.
sendspin::warn_if_port_is_unavailable() {
    local idx=$1 name=$2 port=$3 description=$4 availability=$5
    local port_text

    [ "${availability}" = 'not available' ] || return 0

    port_text="${port}"
    if [ -n "${description}" ]; then
        port_text="${description} (${port})"
    fi

    sendspin::log "The Home Assistant audio output this player plays through is routed to a socket with nothing plugged into it, so nothing it plays will be heard."
    sendspin::log "That output is sink #${idx}, ${name}, and it is playing out of ${port_text}, which PulseAudio reports as not available."
    sendspin::log 'Music Assistant volume cannot fix it: the audio is reaching an empty socket whatever the level is set to.'
    sendspin::log 'Plug into that socket, or pick an output that is plugged in from the Home Assistant Audio panel.'
    sendspin::log 'The routing is shared with every other add-on on this machine, which is why this one will not change it for you.'
}

# One line at every start, healthy or not. The report this check was written
# from had nothing in the log to go on precisely because a healthy start used to
# say nothing, so the next "no audio" arrives with the output already named
# whether or not there is a rule here for what went wrong with it.
sendspin::report_output() {
    local idx=$1 name=$2 description=$3 level=$4 port=$5 port_description=$6
    local out

    out="Playing through sink #${idx}, ${name} (${description}), at ${level}%"
    if [ -n "${port_description}" ] && [ -n "${port}" ]; then
        out="${out}, out of ${port_description} (${port})"
    elif [ -n "${port}" ]; then
        out="${out}, out of ${port}"
    fi
    sendspin::log "${out}."
}

# Everything the check has to say about a sink list, given the list and the name
# of the sink to look for in it. Split from the pactl calls that fetch them so
# that scripts/pactl_parse_test.sh can put a fixture through the whole of it,
# bail-outs included.
sendspin::report_on_sinks() {
    local target=$1 sinks=$2
    local state name
    local -a field names

    if [ -z "${sinks}" ]; then
        sendspin::log 'PulseAudio lists no audio outputs at all, so nothing this player plays will be heard.'
        sendspin::log 'Check that the Home Assistant host has a sound card, and that an output is selected in its Audio panel.'
        return 0
    fi

    [ -n "${target}" ] || return 0

    state=$(sendspin::pulse_sink_state "${target}" <<< "${sinks}") || return 0
    if [ -z "${state}" ]; then
        mapfile -t names < <(sendspin::pulse_sink_names <<< "${sinks}")

        # Nothing came back for two quite different reasons, and saying the
        # wrong one sends the reader after the wrong thing. The sink being in
        # the list means it was pactl's format that could not be read, not the
        # Audio panel selection that was wrong.
        for name in "${names[@]}"; do
            if [ "${name}" = "${target}" ]; then
                sendspin::log "The Home Assistant audio output this player plays through, ${target}, is listed by PulseAudio but could not be read."
                sendspin::log 'That is this add-on failing to parse pactl, not a fault with the output, and it means nothing here can say whether the output is audible.'
                return 0
            fi
        done

        sendspin::log "The Home Assistant audio output this player is set to play through, ${target}, is not among the outputs PulseAudio lists."
        sendspin::log 'PulseAudio falls back to its own default when that happens, so the audio is going to some other device, or to nowhere.'
        if [ "${#names[@]}" -gt 0 ]; then
            sendspin::log 'The outputs it does list are:'
            for name in "${names[@]}"; do
                sendspin::log "    ${name}"
            done
            sendspin::log 'Pick one of them for this player in the Home Assistant Audio panel.'
        fi
        return 0
    fi

    # Command substitution strips trailing newlines, so a sink whose port fields
    # all came back empty arrives as five elements rather than eight. The range
    # still refuses anything short of the five the reading guarantees.
    mapfile -t field <<< "${state}"
    [ "${#field[@]}" -ge 5 ] && [ "${#field[@]}" -le 8 ] || return 0

    sendspin::report_output "${field[0]}" "${field[1]}" "${field[2]}" "${field[4]}" \
        "${field[5]:-}" "${field[6]:-}"
    sendspin::warn_if_sink_is_silent \
        "${field[0]}" "${field[1]}" "${field[2]}" "${field[3]}" "${field[4]}"
    sendspin::warn_if_port_is_unavailable \
        "${field[0]}" "${field[1]}" "${field[5]:-}" "${field[6]:-}" "${field[7]:-}"
}

# Advisory, so every path here returns success: the oneshot runs under
# `set -euo pipefail`, and a PulseAudio that cannot be reached must be a shrug
# rather than a container that never starts.
sendspin::check_output_is_audible() {
    local sinks info target

    # Compose has no PulseAudio at all, so there is no sink to have an opinion
    # about. Saying nothing is the whole behaviour here, not a fallback.
    [ -S "${PULSE_SOCKET}" ] || return 0

    sinks=$(sendspin::pactl list sinks) || return 0

    target=''
    if [ -r "${PULSE_CLIENT_CONF}" ]; then
        target=$(sendspin::pulse_conf_default_sink < "${PULSE_CLIENT_CONF}") || return 0
    fi
    # No point asking the daemon which sink it prefers when it has just said it
    # has none; the empty list is the thing worth reporting there.
    if [ -z "${target}" ] && [ -n "${sinks}" ]; then
        info=$(sendspin::pactl info) || return 0
        target=$(sendspin::pulse_info_default_sink <<< "${info}") || return 0
    fi

    sendspin::report_on_sinks "${target}" "${sinks}"
}
