# Tests

## test_rfhs_checker.sh

Tests `files/usr/sbin/rfhs_checker`, the healthcheck, in a throwaway
container of the openwrt image without any radios. Fakes first in `PATH`
stand in for `iw dev` and `iwinfo` (an AP for each SSID in a list), `ss` (a
list of sockets), `wifi` (which logs what it was asked to do) and the old
checker's `iw <phy> info`, and a tmpfs
over `/sys/class/ieee80211` holds the configured phys. It checks that:

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
- any number of failures exits 1 (docker reserves 2)
- each running SSID gets a status file in `/run/rfctf_status`, with a new
  mtime
- `bootwifi` leaves out the service check, and `excessive` finds every
  command it needs and never restarts the wifi

```sh
docker pull rfhs/openwrt:latest
./tests/test_rfhs_checker.sh                    # this checkout's rfhs_checker
./tests/test_rfhs_checker.sh -c some/rfhs_checker -i rfhs/openwrt:4.6.4
./tests/test_rfhs_checker.sh -w wireless -m 20  # another /etc/config/wireless; measure 20 passes
```

`-m` also prints the CPU (from the container's cgroup) and wall time of a
healthy pass, without and with `/run/rfctf_status`. The fakes are shell
scripts, so they cost more than the real `iw` and `ss`. It prints PASS or FAIL for each check and
exits 1 if any failed. `.github/workflows/test.yml` runs it, with `-m 20`,
against `rfhs/openwrt:latest`.
