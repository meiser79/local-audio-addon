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
