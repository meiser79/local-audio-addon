# Music Assistant local audio

Plays Music Assistant audio out of the machine it runs on, over ALSA.

This repository is packaging only. The player itself is
[`sendspin-cli`](https://github.com/Sendspin/sendspin-cpp-cli), which lives
upstream and is built here from a pinned ref — it is never forked into this
repository. What this repository adds is a container image, and the Home
Assistant app manifest in `local_audio/` that wraps the same image.

The image runs as root, like the Open Home Foundation's other app images.

Discovery and playback are local-network only. There is no reverse-proxy,
HTTPS or overlay-network story, and deployments other than Docker Compose and
the Home Assistant app are not supported.

## Quickstart with Docker Compose

```sh
docker compose up -d
docker compose logs -f
```

Music Assistant discovers the player over mDNS and connects back in on port
8928, which is why the container needs `network_mode: host`. Once the log reads

```
I cli: sendspin-cli 0.1.3 listening on port 8928 as "Living Room" (output: default, mDNS: dns_sd (avahi-compat))
I mdns: advertising _sendspin._tcp. as "Living Room" on port 8928 (path /sendspin)
```

the player is waiting to be picked up in Music Assistant's Sendspin provider.

Configuration is four environment variables, all optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SENDSPIN_NAME` | `Local Audio` | Name shown in Music Assistant |
| `SENDSPIN_OUTPUT` | `default` | ALSA output, see below |
| `SENDSPIN_LOG_LEVEL` | `info` | `none`, `error`, `warn`, `info`, `debug`, `verbose` |
| `SENDSPIN_SERVER` | unset | Dial out to one server instead of being discovered |

## Choosing an output

`default` follows the container's `/etc/asound.conf`, a bare name is an ALSA
PCM, and `null` discards the audio, which is useful for checking that discovery
works before wiring up a sound card.

The image ships no `/etc/asound.conf`. As a Home Assistant app it gets one
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
is what CI will do per architecture once it lands. The build stage is pinned to Debian's
multi-arch *index* digest so that it resolves to whichever architecture is being
built; replacing it with a per-architecture digest would quietly build the
binary for the wrong one.

## Home Assistant app

`local_audio/` is the app manifest, wrapping this same image, so the runtime
behaviour described above is shared. It reads its `name`, `log_level` and
`server` from the app options instead of the environment.

The app plays through the PulseAudio that Home Assistant maps in, and the sound
card is chosen in the app's own Audio panel — it offers no output option of its
own. It cannot open a card directly: the Supervisor grants an app no cgroup rule
for the sound devices unless the app also asks for every other device on the
machine. `hw:` and `plughw:` outputs are therefore a Compose-only capability,
which is the reason to run the container rather than the app for an
exclusively-held DAC.

The app also reads that PulseAudio sink once at start and names it in the log,
with its level and the port it is routed to. If the sink is muted or at zero it
warns with the `ha audio volume output` command that raises it; if the sink is
routed to a port PulseAudio reports as unavailable — a socket with nothing in
it — it says so and points at the Audio panel; and if the selected sink is not
in the list at all, or there are no outputs, it says that too. Each of those is
silence at every Music Assistant volume, and none of them is something the
player can report, since it applies volume as software gain rather than through
a mixer and never opens a mixer to ask. It never writes to the sink: the level
and the routing are shared with every other app and belong to the Audio panel.
The check is app-only: under Compose there is no PulseAudio to ask, and it does
nothing.

## Cutting a release

The version is bumped by the pull request that makes the change, not at release
time: `local_audio/config.yaml` carries it and `local_audio/CHANGELOG.md` gains
its section as part of the work itself. Cutting a release is confirming that
those two say what is about to be published, and then tagging it.

A lightweight `vMAJOR.MINOR.PATCH` tag on a commit on `main` is the only thing
that publishes. `.github/workflows/release.yml` triggers on that and on nothing
else — no branch push, no pull request, no `workflow_dispatch` — so pushing the
tag is the decision, and there is no route to a published image that does not
go through it.

```sh
git tag v0.1.7 <the commit on main> && git push origin v0.1.7
```

The run opens with a preflight, ahead of the matrix so that a mistyped tag
fails in a minute rather than after two half-hour builds. It refuses a tag that
disagrees with the manifest's `version:` — the store card pulls `image:version`,
so a manifest naming a tag nobody pushed is an app that cannot install — and it
refuses anything that is not `vMAJOR.MINOR.PATCH`, which is how `v0.1.7rc1` is
turned away rather than published as `latest` with nobody having decided that
it should be.

Then one leg per architecture builds and pushes its image **by digest**, under
no tag at all, and pulls that digest back to smoke-test the bits that were
pushed rather than the ones that were built. Only with both legs green does the
manifest job tag `:VERSION` and `:latest`, both from one index so that `latest`
cannot come to mean something the version tag does not. A release that fails
halfway therefore leaves nothing installable behind — only unreferenced
digests, which no tag names and nothing will pull.

Once that workflow succeeds, `.github/workflows/sync-store.yml` mirrors
`local_audio/` from the released commit into the store repository and opens a
pull request there; that is the second half of the flow, and **Store card sync**
below covers it. A person merges that pull request, so between the release
finishing and the merge ghcr carries a version the store does not yet offer.

Nothing in CI creates the GitHub Release object. It is written by hand, and it
is where a skipped version is accounted for: not every bump is tagged — 0.1.3
and 0.1.4 were bumped and then delivered by `v0.1.5` — so by convention the
body names the image that was published, says which versions it folds in and
why the store card's version jumps by more than one, and quotes the changelog
sections it is delivering.

## Store card sync

The card the store offers this app from lives in
[`music-assistant/home-assistant-addon`](https://github.com/music-assistant/home-assistant-addon),
and it names both the image and the version to pull, so it has to be bumped for
every release. `.github/workflows/sync-store.yml` does that: once a release has
published, it mirrors `local_audio/` from the released tag into that repository
and opens a pull request there for somebody to merge. It mirrors the whole
directory rather than the version line, so a release that changed the app's
README, translations or apparmor profile carries those across too. The card's
`icon.png` and `logo.png` belong to the store repository and are left alone —
and if this repository ever starts shipping either, the sync stops and says so
rather than deciding on its own which copy wins.

The sync reads a `STORE_SYNC_TOKEN` secret from this repository: a fine-grained
token scoped to `music-assistant/home-assistant-addon` alone, granting
`contents: write` and `pull-requests: write`. Creating it is a manual step, and
until it exists every release fails its sync and says so. The pull requests it
opens are authored by whatever account owns the token; a machine account keeps
the store's history legible if a personal one reads oddly there. A sync that failed
quietly would have no symptom at all: the store would go on offering the
previous version, every install would keep working, and the release would
simply never arrive.

## Health

The image's `HEALTHCHECK` asks the player over its control socket, and, when the
bundled daemons are running, checks that `avahi-daemon` is alive too — a player
that cannot advertise is undiscoverable, which should be visible rather than
look like an idle instance. To query it by hand:

```sh
docker exec ma-local-audio sendspin-cli status \
    --control-socket /run/sendspin-cli/control.sock
```

The Home Assistant Supervisor ignores `HEALTHCHECK`, so this is for the Compose
audience.

A player that exits with an error stops the whole container rather than being
restarted in place: the config is rendered from the environment or the app
options, so nothing can change between attempts, and a stopped container is
visible where an internal crash loop is not. Compose's `restart: unless-stopped`
is the retry policy.

## Licence

Apache-2.0, see [LICENSE](LICENSE). `sendspin-cli` is Apache-2.0 upstream.
