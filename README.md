Really really really quick and extra dirty:

git clone openwrt (probably using openwrt-21.02 branch)
symlink dotconfig to .config in the openwrt dir
symlink files to files in the openwrt dir
make
modify docker-build.sh to point to your generated tarball
run docker-build.sh

docker-build.sh benchmarks the healthcheck with rfctf-container's `tools/bench_healthcheck.sh` before its test, and fails if the median pass takes over 100 ms.  It expects an rfctf-container checkout in `~/development/rfhs/rfctf-container`; set `RFCTF_CONTAINER` for another.

Tests:

`tests/test_rfhs_checker.sh` tests the healthcheck, `files/usr/sbin/rfhs_checker`, in the published image without radios; see `tests/README.md`.  GitHub Actions runs it and ShellCheck (`.github/workflows/test.yml`).
