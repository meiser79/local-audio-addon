# Music Assistant local audio

Plays Music Assistant audio out of the machine it runs on, over ALSA.

This repository is packaging only. The player itself is
[`sendspin-cli`](https://github.com/Sendspin/sendspin-cpp-cli), which lives
upstream and is built here from a pinned ref — it is never forked into this
repository. What this repository adds is a container image, and, arriving in a
follow-up, the Home Assistant add-on manifest that wraps the same image.

The image runs as root, like the Open Home Foundation's other add-on images.

Discovery and playback are local-network only. There is no reverse-proxy,
HTTPS or overlay-network story, and deployments other than Docker Compose and
the Home Assistant add-on are not supported.

## Quickstart with Docker Compose

```sh
docker compose up -d
docker compose logs -f
```

Music Assistant discovers the player over mDNS and connects back in on port
8928, which is why the container needs `network_mode: host`. Once the log reads

```
I cli: sendspin-cli 0.1.0 listening on port 8928 as "Living Room" (output: default, mDNS: dns_sd (avahi-compat))
I mdns: advertising _sendspin._tcp. as "Living Room" on port 8928 (path /sendspin)
```

the player is waiting to be picked up in Music Assistant's Sendspin provider.

Configuration is four environment variables, all optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SENDSPIN_NAME` | the container's hostname | Name shown in Music Assistant |
| `SENDSPIN_OUTPUT` | `default` | ALSA output, see below |
| `SENDSPIN_LOG_LEVEL` | `info` | `none`, `error`, `warn`, `info`, `debug`, `verbose` |
| `SENDSPIN_SERVER` | unset | Dial out to one server instead of being discovered |

## Choosing an output

`default` follows the container's `/etc/asound.conf`, a bare name is an ALSA
PCM, and `null` discards the audio, which is useful for checking that discovery
works before wiring up a sound card.

The image ships no `/etc/asound.conf`. As a Home Assistant add-on it gets one
from the Supervisor, which routes `default` to Home Assistant's PulseAudio;
under Compose there is none, so `default` is ALSA's own default over `/dev/snd`
— usually the first card, not whatever the host routes its audio through. Name
the card explicitly if that is not the one you want. To see what the container
can reach:

```sh
docker exec ma-local-audio sendspin-cli -l
```

then set `SENDSPIN_OUTPUT` to one of the listed names, for example `hw:1,0`.

## Discovery, Avahi and D-Bus

The image bundles `dbus` and `avahi-daemon` so that a plain
`docker compose up` is discoverable with no host setup. Whether they actually
start is decided once, at container start, and the container logs which branch
it took:

- a D-Bus socket is already present at `/var/run/dbus/system_bus_socket`,
  because the host's bus was bind-mounted in — the bundled pair stays down and
  the player advertises through the host's Avahi. Use this when the host already
  runs Avahi, since `network_mode: host` would otherwise put two responders on
  port 5353;
- `SENDSPIN_SERVER` names a plain host or URL — the player dials out and the
  Sendspin spec suppresses the advertisement, so the bundled pair stays down.
  An `mdns:` prefixed value still needs mDNS to resolve the server, so there
  the pair does start;
- otherwise the bundled pair starts.

## State

`/data` holds the player's persistent state — volume, mute, static delay and
the last server it talked to — under `/data/state`. The Compose file keeps it in
a named volume, so a recreated container comes back at the same volume level.

## Bumping the player

`SENDSPIN_CLI_REF` and `SENDSPIN_CLI_SHA` at the top of the `Dockerfile` pin the
upstream ref and the commit it must resolve to. Change both together: the build
compares the clone's `HEAD` against `SENDSPIN_CLI_SHA` and aborts on a mismatch,
so a tag that has been repointed fails the build rather than silently shipping
different code.

The pin is one level deep. Upstream's CMake pulls in the `Sendspin/sendspin-cpp`
core by *tag*, not by commit, so that layer is pinned by upstream rather than
here. The tag in effect for a built image is recorded, along with both ARGs, in
`/usr/share/sendspin-cli/BUILD-INFO.txt`:

```sh
docker exec ma-local-audio cat /usr/share/sendspin-cli/BUILD-INFO.txt
```

`BUILD_FROM` selects the Home Assistant base image and defaults to the amd64
one. Building on another architecture means passing the matching digest, which
is what CI does per architecture. The build stage is pinned to Debian's
multi-arch *index* digest so that it resolves to whichever architecture is being
built; replacing it with a per-architecture digest would quietly build the
binary for the wrong one.

## Home Assistant add-on

The add-on manifest will live in `local_audio/` and wrap this same image, so
the runtime behaviour described above is shared. It reads its `name`, `output`,
`log_level` and `server` from the add-on options instead of the environment.

## Health

The image's `HEALTHCHECK` asks the player over its control socket, and, when the
bundled daemons are running, checks that `avahi-daemon` is alive too — a player
that cannot advertise is undiscoverable, which should be visible rather than
look like an idle instance. To query it by hand:

```sh
docker exec ma-local-audio sendspin-cli status \
    --control-socket /run/sendspin-cli/control.sock
```

The Home Assistant Supervisor runs its own watchdog and ignores `HEALTHCHECK`,
so this is for the Compose audience.

## Licence

Apache-2.0, see [LICENSE](LICENSE). `sendspin-cli` is Apache-2.0 upstream.
