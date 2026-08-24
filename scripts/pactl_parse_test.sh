#!/usr/bin/env bash
#
# Unit checks for the silent-output warning in rootfs/usr/lib/sendspin-cli/common.sh.
#
# The warning is only as good as its reading of `pactl` text, and that text is not this repo's
# to keep stable: a pactl whose format moves would otherwise turn the warning off with no
# symptom anywhere, on an image that still builds and still boots. So the parsing is pinned
# here against canned output rather than left to be noticed in a log.
#
# The fixtures are real `pactl` output, trimmed of the property and port blocks that follow
# every sink -- except where a check is about those blocks not being mistaken for sink fields.
#
# Needs: bash and awk. No docker, no image, no PulseAudio.
#
# Usage: scripts/pactl_parse_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../rootfs/usr/lib/sendspin-cli/common.sh
source "$SCRIPT_DIR/../rootfs/usr/lib/sendspin-cli/common.sh"

FAILURES=0

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

# Every assertion goes through here, so a mismatch always prints both sides rather than just
# the name of the check that went red.
assert_equal() {
    local want=$1 got=$2 what=$3
    if [ "$want" = "$got" ]; then
        pass "$what"
    else
        fail "$what"
        printf '    want: %q\n    got:  %q\n' "$want" "$got" >&2
    fi
}

# ==============================================================================
# The fixtures
# ==============================================================================

# Two sinks, so that picking the right one is asserted rather than assumed: the HDMI sink is
# first and healthy, the analog sink the add-on plays to is second and silent. Both carry the
# `Base Volume:` line, which is the hardware reference level and reads exactly like the level
# being looked for.
readonly TWO_SINKS='Sink #0
	State: SUSPENDED
	Name: alsa_output.pci-0000_00_1f.3.hdmi-stereo
	Description: Built-in Audio Digital Stereo (HDMI)
	Driver: PipeWire
	Sample Specification: s32le 2ch 48000Hz
	Channel Map: front-left,front-right
	Owner Module: 4294967295
	Mute: no
	Volume: front-left: 48497 /  74% / -7.85 dB,   front-right: 48497 /  74% / -7.85 dB
	        balance 0.00
	Base Volume: 65536 / 100% / 0.00 dB
	Monitor Source: alsa_output.pci-0000_00_1f.3.hdmi-stereo.monitor
	Latency: 0 usec, configured 0 usec
	Flags: HARDWARE DECIBEL_VOLUME LATENCY
	Properties:
		alsa.card_name = "HDA Intel PCH"
		device.description = "Built-in Audio Digital Stereo (HDMI)"
	Ports:
		hdmi-output-0: HDMI / DisplayPort (type: HDMI, priority: 5900, not available)
	Active Port: hdmi-output-0
	Formats:
		pcm
Sink #7
	State: SUSPENDED
	Name: alsa_output.usb-Topping_D10s-00.analog-stereo
	Description: D10s Analog Stereo
	Driver: PipeWire
	Sample Specification: s32le 2ch 48000Hz
	Channel Map: front-left,front-right
	Owner Module: 4294967295
	Mute: no
	Volume: front-left: 0 /   0% / -inf dB,   front-right: 0 /   0% / -inf dB
	        balance 0.00
	Base Volume: 65536 / 100% / 0.00 dB
	Monitor Source: alsa_output.usb-Topping_D10s-00.analog-stereo.monitor
	Latency: 0 usec, configured 0 usec
	Flags: HARDWARE HW_MUTE_CTRL HW_VOLUME_CTRL DECIBEL_VOLUME LATENCY
	Properties:
		alsa.card_name = "D10s"
		device.description = "D10s Analog Stereo"
	Ports:
		analog-output: Analog Output (type: Analog, priority: 9900, availability unknown)
	Active Port: analog-output
	Formats:
		pcm'

readonly PACTL_INFO='Server String: /run/audio/pulse.sock
Library Protocol Version: 35
Server Protocol Version: 35
Is Local: yes
Client Index: 121
Tile Size: 65472
User Name: root
Host Name: homeassistant
Server Name: pulseaudio
Server Version: 17.0
Default Sample Specification: s16le 2ch 44100Hz
Default Channel Map: front-left,front-right
Default Sink: alsa_output.pci-0000_00_1f.3.hdmi-stereo
Default Source: alsa_output.pci-0000_00_1f.3.hdmi-stereo.monitor
Cookie: 2966:8795'

# ==============================================================================
# Which sink gets looked at
# ==============================================================================

check_client_conf_default_sink() {
    local conf out

    step 'the sink comes from client.conf'

    # The shape the Supervisor renders per add-on, with the commented-out defaults PulseAudio
    # ships around it. `;` is PulseAudio's comment character, and a commented default-sink is
    # exactly what an add-on with no Audio panel selection gets.
    conf='# Home Assistant audio configuration
default-server = unix:/run/audio/pulse.sock
; default-sink = something-else
default-sink = alsa_output.usb-Topping_D10s-00.analog-stereo
; default-source =
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal 'alsa_output.usb-Topping_D10s-00.analog-stereo' "$out" \
        'default-sink is read, and a commented-out one is not'

    conf='default-server = unix:/run/audio/pulse.sock
; default-sink =
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal '' "$out" 'no default-sink reads as no answer, not as an empty sink name'

    # The key present with nothing after it, which is what the Supervisor renders when the
    # Audio panel has no selection. It has to read as no answer rather than as a sink named
    # the empty string: it is the whole trigger for falling back to the server's own default.
    conf='default-server = unix:/run/audio/pulse.sock
default-sink =
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal '' "$out" 'an empty default-sink reads as no answer'

    conf='default-server = unix:/run/audio/pulse.sock
default-sink =   alsa_output.usb-Topping_D10s-00.analog-stereo   
autospawn = no'
    out=$(sendspin::pulse_conf_default_sink <<< "$conf")
    assert_equal 'alsa_output.usb-Topping_D10s-00.analog-stereo' "$out" \
        'the sink name comes back without the whitespace around it'

    out=$(sendspin::pulse_conf_default_sink < /dev/null)
    assert_equal '' "$out" 'an empty client.conf reads as no answer'
}

check_server_default_sink() {
    local out

    step 'the server default is the fallback'

    out=$(sendspin::pulse_info_default_sink <<< "$PACTL_INFO")
    assert_equal 'alsa_output.pci-0000_00_1f.3.hdmi-stereo' "$out" \
        "the daemon's default sink is read from pactl info"

    # `Default Source:` is the very next line and its name is the sink's with a suffix, so a
    # loose match here would silently inspect the monitor source instead of the sink.
    out=$(sendspin::pulse_info_default_sink <<< 'Default Source: alsa_output.hdmi.monitor')
    assert_equal '' "$out" 'Default Source is not mistaken for Default Sink'
}

# ==============================================================================
# Reading a sink's state
# ==============================================================================

check_sink_state() {
    local out want

    step 'a sink reads back field by field'

    want='7
alsa_output.usb-Topping_D10s-00.analog-stereo
D10s Analog Stereo
no
0'
    out=$(sendspin::pulse_sink_state 'alsa_output.usb-Topping_D10s-00.analog-stereo' <<< "$TWO_SINKS")
    assert_equal "$want" "$out" 'index, name, description, mute and level all parse'

    # The first sink in the list is the healthy one. Reading its 74% rather than the second
    # sink's 0% is what proves the target name selects the block, and `Base Volume: ... 100%`
    # sitting under it is what proves the level is the `Volume:` line and not the next one
    # that looks like it.
    want='0
alsa_output.pci-0000_00_1f.3.hdmi-stereo
Built-in Audio Digital Stereo (HDMI)
no
74'
    out=$(sendspin::pulse_sink_state 'alsa_output.pci-0000_00_1f.3.hdmi-stereo' <<< "$TWO_SINKS")
    assert_equal "$want" "$out" 'the named sink is the one read, and Base Volume is not its level'

    out=$(sendspin::pulse_sink_state 'alsa_output.no-such-card' <<< "$TWO_SINKS")
    assert_equal '' "$out" 'a sink that is not in the list reads as no answer'
}

check_mute_and_level() {
    local out sink

    step 'the mute flag and the level'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: yes
	Volume: front-left: 65536 / 100% / 0.00 dB,   front-right: 65536 / 100% / 0.00 dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 4p)
    assert_equal 'yes' "$out" 'a muted sink reports its mute flag'

    # Only one channel is down. The loudest decides, because a sink is silent only when every
    # channel of it is -- and a lone quiet channel is a balance setting, not a fault.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 0 /   0% / -inf dB,   front-right: 39321 /  60% / -13.33 dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 5p)
    assert_equal '60' "$out" 'the loudest channel is the level'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 0 /   0% / -inf dB,   front-right: 0 /   0% / -inf dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 5p)
    assert_equal '0' "$out" 'every channel down is a level of zero'

    # PulseAudio allows a sink above 100%, and `pactl` prints it. Three digits must not read
    # as some other number.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 98304 / 150% / 7.04 dB,   front-right: 98304 / 150% / 7.04 dB
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 5p)
    assert_equal '150' "$out" 'a level above 100% parses whole'
}

check_garbage_is_no_answer() {
    local out sink

    step 'unparseable output reads as no answer'

    out=$(sendspin::pulse_sink_state sink < /dev/null)
    assert_equal '' "$out" 'empty pactl output reads as no answer'

    out=$(sendspin::pulse_sink_state sink <<< 'Connection failure: Connection refused')
    assert_equal '' "$out" 'an error message reads as no answer'

    # The single field this check turns on. A format change that drops or renames it must
    # read as "could not tell", never as an audible sink.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Base Volume: 65536 / 100% / 0.00 dB'
    out=$(sendspin::pulse_sink_state sink <<< "$sink")
    assert_equal '' "$out" 'a sink with no Volume line reads as no answer'

    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: unavailable'
    out=$(sendspin::pulse_sink_state sink <<< "$sink")
    assert_equal '' "$out" 'a Volume line with no percentage in it reads as no answer'

    # Properties are indented one level deeper than sink fields, which is the only thing
    # keeping a property called `Name` out of the answer.
    sink='Sink #3
	Name: sink
	Description: A sink
	Mute: no
	Volume: front-left: 65536 / 100% / 0.00 dB
	Properties:
		Name: not-the-sink
		Mute: yes'
    out=$(sendspin::pulse_sink_state sink <<< "$sink" | sed -n 4p)
    assert_equal 'no' "$out" 'a property is not mistaken for a sink field'
}

# ==============================================================================
# What gets said
# ==============================================================================

# The whole point of the check is what a user reads in the log, so the message is asserted
# rather than only the numbers behind it.
check_the_warning() {
    local out

    step 'the warning'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 74 2>&1)
    assert_equal '' "$out" 'an audible sink is not mentioned at all'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 100 2>&1)
    assert_equal '' "$out" 'a sink at full is not mentioned at all'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 0 2>&1)
    case $out in
        *'turned down to zero, so nothing it plays will be heard.'*) pass 'a zeroed sink is called zeroed' ;;
        *) fail 'a zeroed sink is called zeroed' ;;
    esac
    case $out in
        *'That output is sink #7, a-sink (A Sink).'*) pass 'the warning names the index, name and description' ;;
        *) fail 'the warning names the index, name and description' ;;
    esac
    case $out in
        *'Music Assistant volume cannot raise it'*) pass "the warning says Music Assistant's volume will not fix it" ;;
        *) fail "the warning says Music Assistant's volume will not fix it" ;;
    esac

    # The two lines a user is meant to paste. Pinned exactly, including the index, because a
    # remedy that has to be worked out is the dead end this warning exists to end.
    case $out in
        *'    ha audio volume output --index 7 --unmute'*) pass 'the unmute command is spelled out with the index' ;;
        *) fail 'the unmute command is spelled out with the index' ;;
    esac
    case $out in
        *'    ha audio volume output --index 7 --volume 85'*) pass 'the volume command is spelled out with the index' ;;
        *) fail 'the volume command is spelled out with the index' ;;
    esac

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' yes 74 2>&1)
    case $out in
        *'is muted, so nothing it plays will be heard.'*) pass 'a muted sink at a normal level is still silent' ;;
        *) fail 'a muted sink at a normal level is still silent' ;;
    esac

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' yes 0 2>&1)
    case $out in
        *'is muted and turned down to zero,'*) pass 'both at once are named together' ;;
        *) fail 'both at once are named together' ;;
    esac

    # Nothing downstream of the reading validates it, so a level the parser could not make
    # sense of must not produce a warning about a sink that may be perfectly audible.
    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no '' 2>&1)
    assert_equal '' "$out" 'an unparseable level says nothing'

    out=$(sendspin::warn_if_sink_is_silent 7 a-sink 'A Sink' no 'n/a' 2>&1)
    assert_equal '' "$out" 'a non-numeric level says nothing'
}

# ==============================================================================
# End to end, against the fixtures
# ==============================================================================

# The reading and the warning wired together the way the oneshot wires them, so a change that
# breaks the seam between them fails here rather than in someone's log.
check_end_to_end() {
    local out state
    local -a field

    step 'reading and warning together'

    state=$(sendspin::pulse_sink_state \
        "$(sendspin::pulse_conf_default_sink <<< 'default-sink = alsa_output.usb-Topping_D10s-00.analog-stereo')" \
        <<< "$TWO_SINKS")
    mapfile -t field <<< "$state"
    out=$(sendspin::warn_if_sink_is_silent "${field[0]}" "${field[1]}" "${field[2]}" \
        "${field[3]}" "${field[4]}" 2>&1)
    case $out in
        *'ha audio volume output --index 7 --volume 85'*)
            pass 'the sink client.conf names is the one warned about, with its own index' ;;
        *)
            fail 'the sink client.conf names is the one warned about, with its own index'
            printf '    got: %q\n' "$out" >&2 ;;
    esac

    # The same list, with the server default selected instead. It is the healthy sink, so
    # taking this path when client.conf names the silent one would warn about nothing while
    # the add-on played to silence.
    state=$(sendspin::pulse_sink_state \
        "$(sendspin::pulse_info_default_sink <<< "$PACTL_INFO")" <<< "$TWO_SINKS")
    mapfile -t field <<< "$state"
    out=$(sendspin::warn_if_sink_is_silent "${field[0]}" "${field[1]}" "${field[2]}" \
        "${field[3]}" "${field[4]}" 2>&1)
    assert_equal '' "$out" 'the server default resolves to the healthy sink and says nothing'
}

main() {
    printf 'pactl parse: checking %s\n' "$SCRIPT_DIR/../rootfs/usr/lib/sendspin-cli/common.sh"

    check_client_conf_default_sink
    check_server_default_sink
    check_sink_state
    check_mute_and_level
    check_garbage_is_no_answer
    check_the_warning
    check_end_to_end

    if [ "$FAILURES" -ne 0 ]; then
        printf '\npactl parse: %d check(s) failed\n' "$FAILURES" >&2
        exit 1
    fi
    printf '\npactl parse: every check passed\n'
}

main
