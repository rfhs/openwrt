# Tests

Every test takes the image to test; none of them falls back to the published
`rfhs/openwrt`.

## Before a push

`docker-build.sh` runs all of these on the image it has just built, and tags it
`latest` or pushes it only when every one passes, with both the image's own
config and the game's:

- `test_image_files.sh`
- `test_rfhs_checker.sh -m 20`, and again with the game's
  `/etc/config/wireless`
- `test_firewall.sh` with the public config, the stand-in and the game's
  overlay, each of which also needs the healthcheck's service check to pass
- `test_healthcheck.sh` with the public config and the game's overlay:
  every benchmarked pass has to pass and the median take at most 100 ms,
  `rfhs_checker excessive` has to pass, and docker's own healthcheck has to
  turn healthy

The CPU the benchmark and `-m` measure is reported, not limited yet. A push
host has to have wctf-restricted; elsewhere the game's config is skipped when
there's no checkout, and nothing can be pushed. The whole run, its output and
the measurements, also goes to `build-logs/`, which git ignores.

## test_rfhs_checker.sh

Tests `files/usr/sbin/rfhs_checker`, the healthcheck, in a throwaway
container of the openwrt image without any radios. Fakes first in `PATH`
stand in for `iw dev` and `iwinfo` (an AP for each SSID in a list), `ss` (a
list of sockets), `wifi` (which logs what it was asked to do) and the old
checker's `iw <phy> info`, and `/sys/class/ieee80211`, on a tmpfs over
`/sys/class`, holds the configured phys, so the host needs no cfg80211. The
container runs without AppArmor confinement, as docker's profile denies
writes under `/sys`. It checks that:

- a healthy pass succeeds, leaves the wifi alone and, with nothing
  configuring the wifi, takes under a second
- a pass waits for `mac80211.sh` to finish
- a configured SSID that isn't running, a running SSID that isn't
  configured, an SSID configured on two APs but running on one and a
  configured phy that is missing each fail, are named in `AP_status`, and
  restart the wifi
- nothing on tcp port 110 or udp port 67 fails without restarting the wifi,
  and `AP_status` then lists the sockets; a listener on port 1100 doesn't
  count as 110
- with pop3 bound to addresses in `/etc/xinetd.d`, each enabled one needs a
  listener on its address, and a missing one is named
- any number of failures exits 1 (docker reserves 2)
- each running SSID gets a status file in `/run/rfctf_status`, with a new
  mtime
- `bootwifi` leaves out the service check, and `excessive` finds every
  command it needs and never restarts the wifi

```sh
./tests/test_rfhs_checker.sh -i image                       # the image's own rfhs_checker
./tests/test_rfhs_checker.sh -i image -c some/rfhs_checker  # another one in its place
./tests/test_rfhs_checker.sh -i image -w wireless -m 20     # another /etc/config/wireless; measure 20 passes
```

`-m` also prints the CPU (from the container's cgroup) and wall time of a
healthy pass, without and with `/run/rfctf_status`. The fakes are shell
scripts, so they cost more than the real `iw` and `ss`. It prints PASS or FAIL for each check and
exits 1 if any failed. `.github/workflows/test.yml` runs this checkout's
`rfhs_checker` in `rfhs/openwrt:latest`, with `-m 20`.

## test_image_files.sh

Checks that an image has this checkout's `files/`: each file's contents and
mode and each symlink, without starting the image. `docker-build.sh` runs it
on every image it builds, as `files/` is what makes the image newer than its
OpenWrt tarball. An image built from an older checkout fails it, so it isn't
in CI, which tests the published image.

```sh
./tests/test_image_files.sh rfhs/openwrt:4.6.4.1
```

It prints PASS or FAIL for each file and exits 1 if any failed.

## test_firewall.sh

Tests what the wifi networks can reach, with docker and no radios or root. It
starts the image unprivileged, with `openwrt_docker_args` and `openwrt_start`
from rfctf-container's `startup/rfhs-helpers.sh`, as the game does, on two
internal networks. Each wifi network gets a container on its VLAN of eth0,
which takes a DHCP lease, so its frames pass the same bridge and firewall zone
as a wifi client's. A container on wan stands in for the internet: it is
openwrt's upstream DHCP and DNS, and holds an address to reach. The networks,
addresses and listening ports all come from the running router, so new ones
are covered without changing the test.

```sh
./tests/test_firewall.sh -i image public
./tests/test_firewall.sh -i image -s tests/firewall-gateway-services restricted tests/firewall
./tests/test_firewall.sh -i image -s ../wctf-restricted/wifi/openwrt/airkraken/gateway-services \
  restricted ../wctf-restricted/wifi/openwrt/airkraken/files
```

`public` tests the image's own config. Every wifi network must:

- get a DHCP lease with its router as the gateway
- have its gateway answer DNS for local names, and resolve internet names
  through it, which are separate checks: the first failing means DNS is down
  and only the second means it has no upstream
- load the admin page
- reach every other wifi network

`restricted` mounts an overlay over the image, as `rfhs-container-init` mounts
the game's. `tests/firewall` is a public stand-in for it, as wctf-restricted
is private. Every wifi network must:

- have the same DHCP and DNS
- reach the internet with TCP, UDP and ping
- be a network and firewall zone of its own, with rules in its zone that
  reject or drop the admin address and the whole admin network
- reach no port of any address of the admin network, nor ping it
- get neither the admin page nor `/ubus` from any address of the router
- reach no address of any other wifi network, the router's or a client's
- have its gateway answer on DHCP, DNS and ping, and on exactly what the `-s`
  file lists for that network, or nothing else without `-s`
- be reachable from the admin network, its gateway and its clients, with
  ping, TCP and UDP, which also shows the replies get back

The `-s` file has one `network port/proto` a line, such as `lan20 80/tcp`,
with `#` comments. A port the gateway answers on that isn't listed fails, as
does a listed one it doesn't answer on, or a network that isn't a wifi network.
`tests/firewall-gateway-services` goes with the stand-in, and the game's sits
next to its overlay, outside `files/`, so it doesn't ship in the image. The
stand-in binds pop3 to lan30's gateway alone, so a pop3 that doesn't listen on
every address is covered without wctf-restricted.

Both also run the image's `rfhs_checker excessive` in the router and need its
service check to pass, so a config whose services listen where the healthcheck
doesn't look fails here rather than in the game. Its wifi check fails without
radios and is left out.

Both then change the firewall in the throwaway router and check that the
probes see it, as a test that can't fail proves nothing. These lines start
`self-check:`; a PASS there means the test works, not that the config has a
hole. The router's boot
scripts that wait for radios are replaced, and `net.ipv4.icmp_ratelimit` is 0,
or some blocked udp ports would go unrefused and look open. A silent udp port
counts as open. It prints what each gateway answers on its own network, and
fails on any routable IPv6 address, which it can't probe.

It doesn't cover traffic between clients of one network, which stays on the
bridge or, with `isolate`, in the AP, so the probes can't see it. The firewall
is what's tested here, and wan is a stand-in, not the game's own uplink.

`docker-build.sh` runs `public`, `restricted tests/firewall` and `restricted`
with the game's overlay, each restricted run with its `-s` file.
`.github/workflows/test.yml` has no wctf-restricted, so it runs `public` and
`restricted tests/firewall` against `rfhs/openwrt:latest`.

## test_healthcheck.sh

Boots the image as the game does, with the game's privileges from
rfctf-container's `startup/rfhs-helpers.sh`, its two networks, and the 10
mac80211_hwsim radios `startup/01_openwrt.start` gives the game's openwrt, and
needs the healthcheck to pass:

- in a container started with `--no-healthcheck`, rfctf-container's
  `tools/bench_healthcheck.sh` fails on any failing pass or a median pass over
  100 ms, and reports the CPU; then `rfhs_checker excessive` has to pass
- in a second container, docker runs the image's own `HEALTHCHECK`, as the
  game does, and it has to turn healthy within the start period and the
  checks after it its retries allow; `unhealthy`, or the container stopping,
  fails at once

```sh
./tests/test_healthcheck.sh -i image public
./tests/test_healthcheck.sh -i image restricted ../wctf-restricted/wifi/openwrt/airkraken/files
```

`restricted` mounts the overlay as `rfhs-container-init` mounts the game's. It
needs sudo for `tools/give_hwsim_radios.sh`, and unloads
mac80211_hwsim between the containers and at the end, so nothing else on the
host may be using its radios. A container that fails is left running, with
`AP_status` printed, for debugging. Each config takes a few minutes, mostly
waiting for docker's first check, which comes one interval after the start.

`docker-build.sh` runs it with the public config and the game's.

## test_bridge_ageing.sh

Measures what `ageing_time 0` on the bridges changes, so clients sharing a MAC
can be weighed against flooding. It adds three docker networks to a wifi
network's bridge as stand-ins for its APs, with a client on each, and needs
neither radios nor root. It prints the same measurements with the bridge learning, with
`ageing_time 0` and learning again: ping and tcp between clients, what goes
out a third port, and ping to a client with another client on the same MAC. It
measures the bridge, so what an AP does with a frame it's given isn't covered.

```sh
./tests/test_bridge_ageing.sh -i image [overlay]
```

overlay defaults to `tests/firewall`. It reports numbers and doesn't pass or
fail, so nothing runs it automatically.
