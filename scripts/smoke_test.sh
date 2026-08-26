#!/usr/bin/env bash
#
# Boot-level checks for a built local-audio image: that it comes up, renders the configuration
# its options asked for, runs its bundled daemons only where they serve a purpose, keeps
# credentials out of what it logs, and fails loudly rather than quietly. The `check_*` functions
# below carry the detail.
#
# The suite runs once per option source, because where the options come from is the riskiest
# logic in the image. `--mode standalone` delivers them as SENDSPIN_* environment variables,
# which is what a Compose user does; `--mode addon` serves them from a stand-in Supervisor over
# the API bashio reads, which is what the add-on does. Every check below is written once and both
# modes deliver to it, so the two paths cannot end up held to different standards.
#
# Needs: docker, and python3 for the stand-in Supervisor in add-on mode.
#
# Usage: scripts/smoke_test.sh <image-ref> [--mode standalone|addon]

set -euo pipefail

MODE=standalone
IMAGE=''

usage() {
    printf 'usage: %s <image-ref> [--mode standalone|addon]\n' "$0" >&2
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --mode)
            # A bare trailing --mode must refuse with the usage line: without
            # this, `MODE=$2` trips `set -u` and the script dies on an unbound
            # variable having printed nothing that says what was wrong.
            [ "$#" -ge 2 ] || {
                usage
                exit 2
            }
            MODE=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            IMAGE=$1
            shift
            ;;
    esac
done

if [ -z "$IMAGE" ]; then
    usage
    exit 2
fi

case $MODE in
    standalone | addon) ;;
    *)
        usage
        exit 2
        ;;
esac

readonly MODE IMAGE

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
readonly FAKE_SUPERVISOR="$SCRIPT_DIR/fake_supervisor.py"

# The option values the checks ask for. A space in the name is deliberate: it is the one option
# whose value reaches both the config file and the mDNS advertisement, and quoting it wrongly is
# the mistake that would show up there. `debug` rather than the default, so that the config
# asserted below proves the level was delivered rather than defaulted.
readonly PLAYER_NAME='Smoke Test Player'
readonly PLAYER_LOG_LEVEL=debug

# TEST-NET-1 (RFC 5737), so a dial-out player has somewhere to aim that no real host answers.
readonly UNREACHABLE_SERVER=192.0.2.1:8927
readonly CREDENTIALLED_SERVER='ws://user:s3cr3t@192.0.2.1:8927/sendspin'
readonly CREDENTIAL=s3cr3t

# Only the add-on path uses this. It is what the Supervisor injects, what the image keys the
# add-on branch off, and what the stand-in refuses a request without -- so a token the container
# failed to forward fails the run rather than passing unnoticed.
readonly SUPERVISOR_TOKEN=smoke-supervisor-token

# `supervisor` is the host the real Supervisor answers on, and the one bashio's default URL
# names. Only the port is test-specific -- the stand-in cannot have 80 on the runner -- so
# SUPERVISOR_API is set to carry it, and bashio's default port is the one thing this cannot
# cover. The image hard-codes neither, so there is nothing left there for it to get wrong.
readonly SUPERVISOR_HOST=supervisor

# Sized for a loaded shared CI runner rather than a laptop: being generous costs nothing unless
# something is already wrong, and every wait returns as soon as its condition holds. The health
# timeout is long because it is waiting on Docker's own schedule: the HEALTHCHECK has a 30s start
# period and a 30s interval.
readonly BOOT_TIMEOUT_S=60
readonly EXIT_TIMEOUT_S=60
readonly HEALTH_TIMEOUT_S=150

# The one deadline that is not ours to choose. It is handed to `docker stop`, so it is the grace
# period the s6 shutdown is held to rather than a deadline on a poll. 10 is the Supervisor's own
# add-on `timeout` option, which defaults to 10 and which local_audio/config.yaml does not set.
# Anything more generous here passes a shutdown that real Home Assistant kills, which is exactly
# how the 137 on every stop went unnoticed.
readonly STOP_TIMEOUT_S=10

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR

# Every container this run creates is named from this, so a run that died without sweeping up
# leaves nothing a later one can collide with.
readonly RUN_PREFIX="sendspin-smoke-$$"

CONTAINERS=()
PLAYER=''
SUPERVISOR_PID=''
SUPERVISOR_PORT=''
SUPERVISOR_MARKER=''
CHECKS=0

fail() {
    printf 'smoke: FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'smoke: ok -- %s\n' "$*"
}

step() {
    CHECKS=$((CHECKS + 1))
    printf '\nsmoke: %s (%s mode)\n' "$1" "$MODE"
}

stop_supervisor() {
    if [ -n "$SUPERVISOR_PID" ]; then
        kill "$SUPERVISOR_PID" 2>/dev/null || true
        wait "$SUPERVISOR_PID" 2>/dev/null || true
    fi
    SUPERVISOR_PID=''
    SUPERVISOR_PORT=''
}

cleanup() {
    local container
    stop_supervisor
    for container in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
        docker rm --force --volumes "$container" >/dev/null 2>&1 || true
    done
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ==============================================================================
# Reading a container
# ==============================================================================
#
# Nothing here pipes `docker logs` into grep: `grep -q` exits at its first match, `docker logs`
# then dies of SIGPIPE, and under `set -o pipefail` the shell reads a *successful* match as a
# failed pipeline. Every assertion below therefore dumps the logs to a file first and greps the
# file.

# Writes a container's combined output to a file and echoes the path. Not an error if the
# container has already exited -- that is the subject of three of the checks.
logs_of() {
    local container=$1
    local path="$WORK_DIR/${container}.log"
    docker logs "$container" >"$path" 2>&1 || true
    printf '%s\n' "$path"
}

# Prints what a container said, labelled, for a failure message. The logs are the only evidence
# a CI run leaves behind.
show_logs() {
    local container=$1
    printf '\n---- %s ----\n' "$container" >&2
    cat "$(logs_of "$container")" >&2
    printf -- '---- end %s ----\n' "$container" >&2
    if [ -n "$SUPERVISOR_PID" ]; then
        printf -- '---- stand-in Supervisor ----\n' >&2
        cat "$WORK_DIR/supervisor.log" >&2
        printf -- '---- end stand-in Supervisor ----\n' >&2
    fi
}

# Waits until `text` -- a fixed string, not a pattern -- appears in a container's output, or
# `limit` seconds pass.
wait_for_log() {
    local container=$1 text=$2 limit=$3
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if grep -F -e "$text" "$(logs_of "$container")" >/dev/null; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

assert_log() {
    local container=$1 text=$2 what=$3
    if ! wait_for_log "$container" "$text" "$BOOT_TIMEOUT_S"; then
        show_logs "$container"
        fail "$what -- no '$text' in the container log"
    fi
    pass "$what"
}

# The mirror of assert_log, for lines that must not appear. What the caller waited for before
# calling this is what makes the absence mean anything: nothing here can prove a line will never
# arrive, only that it has not yet.
refute_log() {
    local container=$1 text=$2 what=$3
    if grep -F -e "$text" "$(logs_of "$container")" >/dev/null; then
        show_logs "$container"
        fail "$what -- '$text' is in the container log and should not be"
    fi
    pass "$what"
}

wait_for_exit() {
    local container=$1 limit=$2
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if [ "$(docker inspect --format '{{.State.Running}}' "$container")" = false ]; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

assert_exit_code() {
    local container=$1 expected=$2 what=$3
    local code
    code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
    if [ "$code" != "$expected" ]; then
        show_logs "$container"
        fail "$what -- the container exited $code, not $expected"
    fi
    pass "$what"
}

# Writes the rendered player configuration to a file and echoes the path.
config_of() {
    local container=$1
    local path="$WORK_DIR/${container}.conf"
    docker exec "$container" cat /run/sendspin-cli/sendspin-cli.conf >"$path" ||
        fail 'the container rendered no /run/sendspin-cli/sendspin-cli.conf'
    printf '%s\n' "$path"
}

assert_config_line() {
    local container=$1 pattern=$2 what=$3
    local path
    path=$(config_of "$container")
    if ! grep -E -e "$pattern" "$path" >/dev/null; then
        printf '\n---- rendered config ----\n' >&2
        cat "$path" >&2
        fail "$what -- no line matching /$pattern/ in the rendered config"
    fi
    pass "$what"
}

refute_config_line() {
    local container=$1 pattern=$2 what=$3
    local path
    path=$(config_of "$container")
    if grep -E -e "$pattern" "$path" >/dev/null; then
        printf '\n---- rendered config ----\n' >&2
        cat "$path" >&2
        fail "$what -- a line matching /$pattern/ is in the rendered config and should not be"
    fi
    pass "$what"
}

# `docker top` runs on the host, so it cannot be defeated by an image that ships no `ps` -- this
# one does not -- and is not something a broken container can answer wrongly. Matching is on the
# daemon binaries' own names, which neither `s6-supervise avahi` nor the `s6-pause` standing in
# for a service left down contains.
processes_of() {
    local container=$1
    local path="$WORK_DIR/${container}.procs"
    docker top "$container" >"$path" || fail 'could not read the container process list'
    printf '%s\n' "$path"
}

assert_process() {
    local container=$1 name=$2 what=$3
    local path
    path=$(processes_of "$container")
    if ! grep -F -e "$name" "$path" >/dev/null; then
        printf '\n---- container processes ----\n' >&2
        cat "$path" >&2
        fail "$what -- '$name' is not running"
    fi
    pass "$what"
}

refute_process() {
    local container=$1 name=$2 what=$3
    local path
    path=$(processes_of "$container")
    if grep -F -e "$name" "$path" >/dev/null; then
        printf '\n---- container processes ----\n' >&2
        cat "$path" >&2
        fail "$what -- '$name' is running and should not be"
    fi
    pass "$what"
}

# ==============================================================================
# The stand-in Supervisor
# ==============================================================================

# Starts the stand-in on a port the OS picks, serving the options given.
start_supervisor() {
    local name=$1 output=$2 log_level=$3 server=$4
    local log="$WORK_DIR/supervisor.log"
    local waited=0

    stop_supervisor
    SUPERVISOR_MARKER="$WORK_DIR/supervisor-requests-${CHECKS}"
    : >"$log"

    python3 "$FAKE_SUPERVISOR" \
        --token "$SUPERVISOR_TOKEN" \
        --marker "$SUPERVISOR_MARKER" \
        --option "name=$name" \
        --option "output=$output" \
        --option "log_level=$log_level" \
        --option "server=$server" \
        >"$log" 2>&1 &
    SUPERVISOR_PID=$!

    # Waited for rather than assumed: bashio's fetch does not retry, and the oneshot that makes
    # it is on a 30s timeout, so a stand-in still binding its port when the player asks would
    # fail the run for the wrong reason.
    while [ "$waited" -lt "$((BOOT_TIMEOUT_S * 10))" ]; do
        if grep -F -e 'listening on port ' "$log" >/dev/null 2>&1; then
            SUPERVISOR_PORT=$(sed -n 's/.*listening on port \([0-9]*\).*/\1/p' "$log" | head -1)
            [ -n "$SUPERVISOR_PORT" ] || fail 'the stand-in Supervisor printed no port'
            return 0
        fi
        if ! kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
            cat "$log" >&2
            fail 'the stand-in Supervisor died before it was listening'
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    cat "$log" >&2
    fail 'the stand-in Supervisor never reported a port'
}

# Every request the stand-in answered since it was started, one outcome per line. `ok <header>`
# is an authenticated fetch of the one route it serves; anything else is a request that should
# not have happened.
assert_supervisor_requests() {
    local what=$1
    local unexpected

    [ -s "$SUPERVISOR_MARKER" ] || fail "$what -- the stand-in Supervisor was never asked"
    unexpected=$(grep -c -v -e '^ok ' "$SUPERVISOR_MARKER" || true)
    if [ "$unexpected" != 0 ]; then
        cat "$SUPERVISOR_MARKER" >&2
        fail "$what -- $unexpected request(s) arrived unauthenticated or off-route"
    fi
    pass "$what: $(head -1 "$SUPERVISOR_MARKER")"
}

# ==============================================================================
# Starting a player
# ==============================================================================

# Removes the player, and stops the stand-in Supervisor, of the check before this one. The checks
# run strictly in sequence and never want two players at once.
retire_player() {
    if [ -n "$PLAYER" ]; then
        docker rm --force --volumes "$PLAYER" >/dev/null 2>&1 || true
    fi
    PLAYER=''
    stop_supervisor
}

# Starts a player with the given options and leaves its container name in $PLAYER. Options are
# named key=value pairs, and an option left out is one the user did not set -- so the image's own
# default applies, which is worth being able to test.
#
# This is the only place the two --mode paths differ, so a check says what it wants and never how
# it is delivered.
#
# The name comes back in a global rather than on stdout because a command substitution would run
# all of this in a subshell, where the container it started is tracked for cleanup in a copy of
# the list that dies with it.
start_player() {
    local name='' output='' log_level='' server=''
    local pair key value
    local -a args

    for pair in "$@"; do
        key=${pair%%=*}
        value=${pair#*=}
        case $key in
            name) name=$value ;;
            output) output=$value ;;
            log_level) log_level=$value ;;
            server) server=$value ;;
            *) fail "start_player: unknown option '$key'" ;;
        esac
    done

    retire_player
    PLAYER="${RUN_PREFIX}-player-${CHECKS}"
    args=(--detach --name "$PLAYER")

    if [ "$MODE" = addon ]; then
        start_supervisor "$name" "$output" "$log_level" "$server"
        args+=(--add-host "${SUPERVISOR_HOST}:host-gateway")
        args+=(--env "SUPERVISOR_TOKEN=$SUPERVISOR_TOKEN")
        args+=(--env "SUPERVISOR_API=http://${SUPERVISOR_HOST}:${SUPERVISOR_PORT}")
    else
        if [ -n "$name" ]; then args+=(--env "SENDSPIN_NAME=$name"); fi
        if [ -n "$output" ]; then args+=(--env "SENDSPIN_OUTPUT=$output"); fi
        if [ -n "$log_level" ]; then args+=(--env "SENDSPIN_LOG_LEVEL=$log_level"); fi
        if [ -n "$server" ]; then args+=(--env "SENDSPIN_SERVER=$server"); fi
    fi

    CONTAINERS+=("$PLAYER")
    docker run "${args[@]}" "$IMAGE" >/dev/null || fail "could not start $IMAGE"
}

# Waits for Docker to report the container healthy, or `limit` seconds pass. This is the
# HEALTHCHECK instruction's own verdict rather than a direct run of the script it names: a
# malformed CMD leaves a container `starting` forever, and nothing invoking the script by hand
# would notice.
wait_for_health() {
    local container=$1 limit=$2
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if [ "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy ]; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# Runs the health check script directly and returns its exit status. Where the wait above asserts
# Docker's verdict, this asserts the script's -- which is the only way to get one out of a
# container Docker has not got round to probing yet.
healthcheck() {
    docker exec "$1" /usr/bin/container-healthcheck
}

wait_for_healthcheck() {
    local container=$1 limit=$2
    local waited=0
    while [ "$waited" -lt "$((limit * 10))" ]; do
        if healthcheck "$container" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# Stops a player the way the Supervisor stops the add-on, and asserts it got there under its own
# power. Two things have to hold and they fail differently: the container's exit code says whether
# it beat the grace period, and the s6 shutdown's own running commentary says whether every
# service went down or the list stopped part-way through on one that would not answer.
#
# Every daemon decision runs this, not just the advertise one. The `s6-pause` decisions bring a
# different set of processes down, and nothing else in this suite ever stops them.
assert_clean_stop() {
    local container=$1
    local log service

    docker stop --timeout "$STOP_TIMEOUT_S" "$container" >/dev/null ||
        fail "docker stop exited $? -- s6 did not shut the services down"

    # `docker stop` returns 0 even where it gave up waiting and sent SIGKILL, so its own status
    # proves nothing. The container's does: a killed one reports 137.
    assert_exit_code "$container" 0 'the container stops cleanly within the grace period'

    # The container has exited, so its log is complete -- a line that is not there now never
    # arrives, and there is nothing to wait for.
    log=$(logs_of "$container")
    for service in sendspin-cli avahi dbus; do
        if ! grep -F -e "service ${service} successfully stopped" "$log" >/dev/null; then
            show_logs "$container"
            fail "the s6 shutdown never brought ${service} down -- it ended part-way through"
        fi
        pass "the ${service} service stopped on request rather than being killed"
    done
}

# ==============================================================================
# The checks
# ==============================================================================

# The default connection mode, and the one the add-on ships: no server configured, so the player
# advertises itself and waits to be found. Everything the image exists for is on this path -- the
# bundled dbus, avahi-daemon, and the avahi-compat shim the player registers through -- so it is
# asserted end to end as well as by its parts.
check_advertise_mode() {
    local container mode status_out
    step 'advertise mode'
    start_player "name=$PLAYER_NAME" 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    assert_log "$container" \
        'Starting the bundled dbus and avahi-daemon to advertise this player over mDNS.' \
        'the daemon decision is recorded and says to start them'
    assert_log "$container" "Advertising \"${PLAYER_NAME}\" over mDNS" \
        'the connection mode is logged, with the name quoted as given'
    assert_log "$container" 'listening on port 8928' \
        'the player came up on its port'

    # `mdns: ` and the lower-case verb are both load-bearing. The player's line for the opposite
    # case reads `mdns: Not advertising _sendspin._tcp`, so the bare verb and the service name
    # appear in the log whether or not anything was ever advertised.
    assert_log "$container" 'mdns: advertising _sendspin._tcp' \
        'the player registered its service with the bundled avahi-daemon'

    # The player warns and retries rather than failing when a registration is refused, so the
    # line above can arrive on a second attempt with the first having gone wrong. Nothing about
    # a slow-but-working daemon should read the same as a broken one.
    refute_log "$container" 'could not register' \
        'the registration was not refused on the way there'

    # Neither mode delivers a PulseAudio, so the silent-output check has no socket to find and
    # has to stay quiet. The player being up above is what makes this absence mean something.
    refute_log "$container" 'The Home Assistant audio output this player plays through' \
        'no PulseAudio means the silent-output check says nothing at all'

    # The check also names the output on every start now, which is the line most likely to leak
    # out from under the socket guard, since it does not wait for anything to be wrong first.
    refute_log "$container" 'Playing through sink #' \
        'and it does not name an output it never found either'

    # Nothing else in the image uses `pactl`, so a dropped Dockerfile line would take the
    # warning with it and leave every other check green.
    docker exec "$container" sh -c 'command -v pactl' >/dev/null 2>&1 ||
        fail 'pactl is not in the image -- the silent-output check could never run'
    pass 'pactl is in the image for the silent-output check'

    # `avahi-browse` would be the other half of this -- resolving the record from outside the
    # player -- but the image ships no avahi-utils, and installing them into the container under
    # test would change the subject of the test. The register line above is the daemon's own
    # answer back over D-Bus, so the compat shim, the bus and avahi are all proven by it; what is
    # left unproven is the wire, which a runner with no multicast cannot answer for anyway.
    assert_process "$container" avahi-daemon 'the bundled avahi-daemon is running'
    assert_process "$container" dbus-daemon 'the bundled dbus-daemon is running'

    assert_config_line "$container" "^name = ${PLAYER_NAME}\$" \
        'the name reached the rendered config intact'
    assert_config_line "$container" '^output = null$' \
        'the output reached the rendered config'
    assert_config_line "$container" "^log-level = ${PLAYER_LOG_LEVEL}\$" \
        'the log level reached the rendered config'
    refute_config_line "$container" '^server' \
        'an unset server is left out of the config rather than written empty'

    mode=$(docker exec "$container" stat -c %a /run/sendspin-cli/sendspin-cli.conf)
    [ "$mode" = 600 ] || fail "the rendered config is mode $mode, not 600"
    pass 'the rendered config is readable only by root'

    status_out="$WORK_DIR/${container}.status"
    docker exec "$container" \
        sendspin-cli status --control-socket /run/sendspin-cli/control.sock >"$status_out" 2>&1 ||
        fail "sendspin-cli status exited $? -- $(cat "$status_out")"
    if ! grep -F -e 'output: null' "$status_out" >/dev/null; then
        cat "$status_out" >&2
        fail 'the control socket did not report the configured output'
    fi
    pass 'the control socket answers and reports the configured output'

    healthcheck "$container" >/dev/null || fail "the health check exited $?"
    pass 'the health check passes'

    wait_for_health "$container" "$HEALTH_TIMEOUT_S" || {
        show_logs "$container"
        fail "docker reports the container $(docker inspect \
            --format '{{.State.Health.Status}}' "$container"), not healthy"
    }
    pass 'docker reports the container healthy, so the HEALTHCHECK instruction runs'

    assert_clean_stop "$container"
}

# The name a user who never opened the configuration screen ends up with. It is a fixed string
# now rather than the host's name, so nothing outside the image decides it -- which is what makes
# it worth asserting in both modes: add-on mode reaches the same default through an empty `name`
# option rather than through an unset variable.
check_default_name() {
    local container
    step 'the default player name'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    assert_log "$container" 'Advertising "Local Audio" over mDNS' \
        'a player nobody named advertises itself as Local Audio'
    assert_config_line "$container" '^name = Local Audio$' \
        'and that is the name the rendered config carries'
}

# An `mdns:` server is the third of the four daemon decisions and the odd one out: a server is
# configured, so the player does not advertise, and yet the daemons are needed anyway because
# mDNS is how that server's name gets resolved. Leaving them down here would give a player that
# can never find the thing it was told to connect to.
check_mdns_server_mode() {
    local container
    step 'mDNS-resolved server'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" 'server=mdns:Living Room'
    container=$PLAYER

    assert_log "$container" \
        'Starting the bundled dbus and avahi-daemon: the mdns: server value needs mDNS to resolve the server.' \
        'the daemon decision is recorded and says to start them for the lookup'
    assert_log "$container" \
        'Resolving the Music Assistant server over mDNS (mdns:Living Room); this player is not advertised.' \
        'the connection mode is logged as resolving over mDNS'
    assert_log "$container" 'listening on port 8928' 'the player came up on its port'
    assert_process "$container" avahi-daemon 'the bundled avahi-daemon is running for the lookup'
    refute_log "$container" 'mdns: advertising _sendspin._tcp' \
        'the player advertises nothing when it has a server to reach'

    assert_clean_stop "$container"
}

# A fixed server suppresses the mDNS advertisement, which makes the bundled daemons dead weight
# -- so they are never started, and the health check must not go asking for one that is not
# there. The server is unreachable on purpose: what is under test is the decision, not a
# handshake.
check_dial_out_mode() {
    local container
    step 'dial-out mode'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" "server=$UNREACHABLE_SERVER"
    container=$PLAYER

    assert_log "$container" \
        'A fixed server is configured, which suppresses the mDNS advertisement: the bundled dbus and avahi-daemon stay down.' \
        'the daemon decision is recorded and says to keep them down'
    assert_log "$container" "Dialling out to ${UNREACHABLE_SERVER}; this player is not advertised." \
        'the connection mode is logged as dialling out'

    wait_for_healthcheck "$container" "$BOOT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'the health check never passed in dial-out mode'
    }
    pass 'the health check passes without a bundled avahi to ask'

    assert_config_line "$container" "^server = ${UNREACHABLE_SERVER}\$" \
        'the server reached the rendered config'
    assert_log "$container" 'mdns: Not advertising _sendspin._tcp' \
        'the player says it is not advertising, and why'
    refute_log "$container" 'mdns: advertising _sendspin._tcp' \
        'the player advertises nothing when it has a server to dial'
    refute_process "$container" avahi-daemon 'no avahi-daemon is running'
    refute_process "$container" dbus-daemon 'no dbus-daemon is running'

    assert_clean_stop "$container"
}

# A server value can carry credentials, and the connection-mode line is the first thing that gets
# pasted into a support thread -- so that line is written with the userinfo stripped out.
#
# That line only. The player logs the URL it was handed in full, at info level, and that is
# upstream behaviour in a component this repo builds rather than owns; asserting the credential
# appears nowhere in the log would be asserting something this image cannot deliver. What it can
# deliver is its own line, and a config file only root can read.
check_credentials_are_kept_out_of_the_mode_line() {
    local container
    step 'credentials in a server value'
    start_player 'output=null' "log_level=$PLAYER_LOG_LEVEL" "server=$CREDENTIALLED_SERVER"
    container=$PLAYER

    assert_log "$container" \
        'Dialling out to ws://192.0.2.1:8927/sendspin; this player is not advertised.' \
        'the connection mode is logged with the userinfo stripped'
    refute_log "$container" "Dialling out to ws://user:${CREDENTIAL}" \
        'the line this image writes carries no credentials'
    assert_config_line "$container" "^server = ${CREDENTIALLED_SERVER}\$" \
        'the credentials still reach the player, which needs them'
}

# The one option value that could rewrite the configuration rather than fill it in: a newline
# turns one option into two config keys, and an injected `server` flips the connection mode and
# takes the advertisement with it without saying so. Refused rather than escaped, and the refusal
# has to stop the container -- a player started on a config somebody else wrote is worse than one
# that never started at all.
check_newline_in_an_option() {
    local container
    step 'a newline in an option value'
    start_player "name=x
server = evil" 'output=null'
    container=$PLAYER

    wait_for_exit "$container" "$EXIT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'an option carrying a newline left the container running'
    }
    pass 'an option carrying a newline stops the container'

    assert_exit_code "$container" 1 'the container exits 1 on a refused option'
    assert_log "$container" \
        'SENDSPIN_NAME contains a newline, which would inject configuration keys.' \
        'the log names the option it refused, and why'
    refute_log "$container" 'listening on port 8928' \
        'no player was started on the injected config'
}

# An output the host cannot open is the likeliest way for this image to be misconfigured, and the
# one failure a user cannot see: the Supervisor calls a running container a healthy add-on
# whatever is crash-looping inside it. So the player's error exit halts the container, and that
# is what is asserted -- a stopped add-on with a reason in the log.
check_crash_visibility() {
    local container
    step 'crash visibility'
    start_player 'output=hw:99,0' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    wait_for_exit "$container" "$EXIT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'a player that cannot open its output left the container running'
    }
    pass 'a player that cannot open its output stops the container'

    assert_exit_code "$container" 1 "the container carries the player's exit code out"
    assert_log "$container" 'sendspin-cli exited 1; stopping the container.' \
        'the halt says which exit code stopped the container'
}

# That the options the checks above asserted really did come over the API, authenticated. Without
# this, add-on mode would still pass on an image that ignored the Supervisor entirely and fell
# through to its defaults -- `null` is not one of those defaults, but a check that never looks at
# who answered cannot say so.
check_supervisor_was_asked() {
    local container
    step 'the options came from the Supervisor'
    start_player "name=$PLAYER_NAME" 'output=null' "log_level=$PLAYER_LOG_LEVEL"
    container=$PLAYER

    assert_log "$container" 'listening on port 8928' 'the player came up on its port'
    assert_supervisor_requests 'the stand-in Supervisor was asked, and only for its one route'
    assert_config_line "$container" "^name = ${PLAYER_NAME}\$" \
        'the name in the config came from the API rather than the default'
    assert_config_line "$container" '^output = null$' \
        'an output of null survived the fetch as a value rather than becoming a default'
}

# The add-on path's own failure mode, and the reason the options are fetched once rather than per
# key: a Supervisor that cannot be reached must stop the container, not let every option fall
# through to a default and run a player nobody configured.
#
# Unreachable here means refused, from inside the container, which needs nothing of the host and
# happens at once. A black-holed address would instead prove the oneshot's `timeout-up`, at the
# cost of thirty seconds a run; either asserts the same failure.
check_supervisor_unreachable() {
    local container
    step 'unreachable Supervisor'
    retire_player
    container="${RUN_PREFIX}-player-${CHECKS}"
    PLAYER=$container
    CONTAINERS+=("$container")
    docker run --detach --name "$container" \
        --env "SUPERVISOR_TOKEN=$SUPERVISOR_TOKEN" \
        --env 'SUPERVISOR_API=http://127.0.0.1:1' \
        "$IMAGE" >/dev/null || fail "could not start $IMAGE"

    wait_for_exit "$container" "$EXIT_TIMEOUT_S" || {
        show_logs "$container"
        fail 'an add-on that cannot reach the Supervisor left the container running'
    }
    pass 'an add-on that cannot reach the Supervisor stops the container'

    assert_log "$container" 'Could not read the add-on options from the Supervisor.' \
        'the log says the options could not be read'
    refute_log "$container" 'listening on port 8928' \
        'no player was started on defaults nobody chose'
}

main() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 ||
        fail "no such image '$IMAGE' -- build it first, or pass one that exists"

    if [ "$MODE" = addon ]; then
        [ -f "$FAKE_SUPERVISOR" ] || fail "no stand-in Supervisor at '$FAKE_SUPERVISOR'"
        command -v python3 >/dev/null ||
            fail 'add-on mode needs python3 for the stand-in Supervisor'
    fi

    printf 'smoke: testing %s in %s mode\n' "$IMAGE" "$MODE"

    check_advertise_mode
    check_default_name
    check_mdns_server_mode
    check_dial_out_mode
    check_credentials_are_kept_out_of_the_mode_line
    check_newline_in_an_option
    check_crash_visibility
    if [ "$MODE" = addon ]; then
        check_supervisor_was_asked
        check_supervisor_unreachable
    fi

    printf '\nsmoke: every check passed (%s mode)\n' "$MODE"
}

main
