Really really really quick and extra dirty:

git clone openwrt (probably using openwrt-21.02 branch)
symlink dotconfig to .config in the openwrt dir
symlink files to files in the openwrt dir
make
modify docker-build.sh to point to your generated tarball
run docker-build.sh

docker-build.sh only needs `bin/targets/x86/64` from that build, not the rest of the OpenWrt tree: it takes the tarball's name from `config.buildinfo` beside it.  The Dockerfile adds `files/` on top of the tarball, so changes there don't need a new OpenWrt build.  `IMAGE_VERSION` in docker-build.sh is the tarball's version plus the image's own revision; bump that revision when `files/` changes.

docker-build.sh tests the image it builds and tags it `latest`, or pushes it, only when every test passes on both the image's own config and the game's.  It expects an rfctf-container checkout in `~/development/rfhs/rfctf-container`; set `RFCTF_CONTAINER` for another.  The tests run with the game's privileges from that checkout's `startup/rfhs-helpers.sh`, never `--privileged`, and only need root to give the container its radios with `tools/give_hwsim_radios.sh`.

Tests:

`tests/README.md` describes each test, and what docker-build.sh runs before a push.  In short, docker-build.sh tests the image it has just built, never the published one, with the image's own config and the game's:

- `tests/test_image_files.sh` checks that the image has this checkout's `files/`.
- `tests/test_rfhs_checker.sh` tests the healthcheck, `files/usr/sbin/rfhs_checker`, without radios, with each config's wireless.
- `tests/test_firewall.sh` checks what the wifi networks can reach, and that the healthcheck finds its services listening, with the public config, a public stand-in for the game's and the game's.
- `tests/test_healthcheck.sh` boots the image with mac80211_hwsim radios, as the game does.  `rfhs_checker excessive` has to pass, then every benchmarked pass of the healthcheck has to pass and the median take at most 100 ms, and docker's own healthcheck has to turn healthy.

It pushes only from Nu or naga, which have the credentials, and only when all of them pass, so a host that pushes must have a wctf-restricted checkout, in `~/development/rfhs/wctf-restricted` or at `WCTF_RESTRICTED`.  Elsewhere it skips the game's config when there's no checkout, and then can't push.  The benchmarks' CPU numbers are reported, not limited yet; each run's output goes to `build-logs/` so they can be compared across builds.

GitHub Actions (`.github/workflows/test.yml`) runs ShellCheck, and runs `test_rfhs_checker.sh` and `test_firewall.sh` with the public config and the stand-in on `rfhs/openwrt:latest`, with this checkout's `rfhs_checker` in the first.  It has no wctf-restricted and builds no image, so it doesn't stand in for docker-build.sh's tests.
