Really really really quick and extra dirty:

git clone openwrt (probably using openwrt-21.02 branch)
symlink dotconfig to .config in the openwrt dir
symlink files to files in the openwrt dir
make
modify docker-build.sh to point to your generated tarball
run docker-build.sh

docker-build.sh only needs `bin/targets/x86/64` from that build, not the rest of the OpenWrt tree: it takes the tarball's name from `config.buildinfo` beside it.  The Dockerfile adds `files/` on top of the tarball, so changes there don't need a new OpenWrt build.  `IMAGE_VERSION` in docker-build.sh is the tarball's version plus the image's own revision; bump that revision when `files/` changes.

docker-build.sh benchmarks the healthcheck with rfctf-container's `tools/bench_healthcheck.sh` before its test, and fails if the median pass takes over 100 ms.  It expects an rfctf-container checkout in `~/development/rfhs/rfctf-container`; set `RFCTF_CONTAINER` for another.  The test runs with the game's privileges from that checkout's `startup/rfhs-helpers.sh`, never `--privileged`, and only needs root to give the container its radios with `tools/give_hwsim_radios.sh`.

Tests:

`tests/test_rfhs_checker.sh` tests the healthcheck, `files/usr/sbin/rfhs_checker`, in the published image without radios; see `tests/README.md`.  GitHub Actions runs it and ShellCheck (`.github/workflows/test.yml`).  `tests/test_image_files.sh` checks that an image has this checkout's `files/`, and `tests/test_firewall.sh` checks what its wifi networks can reach; docker-build.sh runs both on the image it builds, with the public config, the stand-in and the game's config.  It pushes only from Nu or naga, which have the credentials, and only when all of them pass, so a host that pushes must have a wctf-restricted checkout, in `~/development/rfhs/wctf-restricted` or at `WCTF_RESTRICTED`.  Elsewhere it skips the game's config when there's no checkout.  CI has no wctf-restricted, so it tests the public config and the stand-in.
