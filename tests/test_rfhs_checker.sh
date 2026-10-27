#!/bin/sh
# Tests rfhs_checker in a throwaway container of the openwrt image, with fakes
# first in PATH for iwinfo, ss, iw and wifi, and a tmpfs over
# /sys/class/ieee80211 holding the configured phys.
#   ./tests/test_rfhs_checker.sh [-c checker] [-i image] [-w wireless] [-m runs]
# -c defaults to this checkout's files/usr/sbin/rfhs_checker and -i to
# rfhs/openwrt:latest; -w replaces /etc/config/wireless; -m also measures the
# CPU and wall time of that many healthy passes.
set -eu

missing_tools=""
for tool in dirname docker grep sed sort; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi

checker="$(dirname "${0}")/../files/usr/sbin/rfhs_checker"
image=rfhs/openwrt:latest
wireless=""
runs=""
while getopts c:i:w:m: opt; do
  case "${opt}" in
    c) checker="${OPTARG}";;
    i) image="${OPTARG}";;
    w) wireless="${OPTARG}";;
    m) runs="${OPTARG}";;
    *) exit 2;;
  esac
done

c="rfhs-checker-test-$$"
docker run -d --rm --name "${c}" --tmpfs /run:mode=0755,nosuid,nodev \
  --tmpfs /sys/class/ieee80211 --entrypoint /bin/sleep "${image}" 3600 > /dev/null
trap 'docker rm -f "${c}" > /dev/null 2>&1 || true' EXIT
docker cp -q "${checker}" "${c}:/usr/sbin/rfhs_checker"
if [ -n "${wireless}" ]; then
  docker cp -q "${wireless}" "${c}:/etc/config/wireless"
fi
docker exec "${c}" sh -c 'mkdir /tmp/rfhs-test && chmod 755 /usr/sbin/rfhs_checker
  cp /etc/config/wireless /tmp/rfhs-test/wireless.orig
  touch -d "2000-01-01 00:00:00" /.dockerenv'

# One fake SSID per line of ssids, then an interface with none
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/iwinfo' << 'EOF'
#!/bin/sh
n=0
while read -r ssid; do
  printf 'wlan%s     ESSID: "%s"\n' "${n}" "${ssid}"
  printf '          Access Point: 02:00:00:00:%02x:00\n' "${n}"
  printf '          Mode: Master  Channel: 11 (2.462 GHz)  HT Mode: HT20\n'
  printf '          Signal: unknown  Noise: unknown\n'
  printf '          Encryption: WPA2 PSK (CCMP)\n'
  printf '          Supports VAPs: yes  PHY name: zphy0b\n\n'
  n=$((n + 1))
done < /tmp/rfhs-test/ssids
printf 'wlan%s     ESSID: unknown\n          Access Point: 00:00:00:00:00:00\n\n' "${n}"
EOF
# The sockets in sockets, laid out as ss lays them out for the protocols asked for
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/ss' << 'EOF'
#!/bin/sh
header=1 tcp=0 udp=0 procs=0
for arg in "$@"; do
  case "${arg}" in
    -*)
      case "${arg}" in *H*) header=0;; esac
      case "${arg}" in *t*) tcp=1;; esac
      case "${arg}" in *u*) udp=1;; esac
      case "${arg}" in *p*) procs=1;; esac
      ;;
  esac
done
both=$((tcp && udp))
if [ "${header}" = 1 ]; then
  if [ "${both}" = 1 ]; then printf 'Netid '; fi
  printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
fi
while read -r netid state recvq sendq local peer; do
  case "${netid}" in
    tcp) [ "${tcp}" = 1 ] || continue;;
    udp) [ "${udp}" = 1 ] || continue;;
  esac
  if [ "${both}" = 1 ]; then printf '%s ' "${netid}"; fi
  printf '%s %s %s %s %s' "${state}" "${recvq}" "${sendq}" "${local}" "${peer}"
  if [ "${procs}" = 1 ]; then printf ' users:(("fake",pid=1,fd=3))'; fi
  printf '\n'
done < /tmp/rfhs-test/sockets
EOF
# iw dev: an AP for each SSID in ssids, then an interface with none
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/iw' << 'EOF'
#!/bin/sh
if [ "$*" = dev ]; then
  n=0
  while read -r ssid; do
    printf 'phy#0\n\tInterface wlan%s\n\t\tifindex %s\n\t\taddr 02:00:00:00:%02x:00\n\t\tssid %s\n\t\ttype AP\n' \
      "${n}" "$((n + 10))" "${n}" "${ssid}"
    n=$((n + 1))
  done < /tmp/rfhs-test/ssids
  printf 'phy#1\n\tInterface wlan%s\n\t\tifindex %s\n\t\ttype managed\n' "${n}" "$((n + 10))"
  exit 0
fi
[ "${2:-}" = info ] && [ -e "/sys/class/ieee80211/${1}" ]
EOF
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/wifi' << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> /tmp/rfhs-test/wifi.log
EOF
# stands in for wifi being configured, for as long as it runs
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/mac80211.sh' << 'EOF'
#!/bin/sh
sleep 2
EOF
# Puts back the config, every configured SSID running, pop3 and dhcp
# listening and every configured phy present
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/reset' << 'EOF'
#!/bin/sh
t=/tmp/rfhs-test
if [ -e /usr/bin/seq.hidden ]; then mv /usr/bin/seq.hidden /usr/bin/seq; fi
cp "${t}/wireless.orig" /etc/config/wireless
awk '!/^#/ && / ssid / { gsub("\047", ""); print $3 }' /etc/config/wireless > "${t}/ssids"
echo OpenWrt >> "${t}/ssids"
printf '%s\n' 'tcp LISTEN 0 5 0.0.0.0:110 0.0.0.0:*' 'tcp LISTEN 0 5 0.0.0.0:22 0.0.0.0:*' \
  'udp UNCONN 0 0 0.0.0.0:67 0.0.0.0:*' 'udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:*' > "${t}/sockets"
rm -rf /sys/class/ieee80211/* /run/rfctf_status "${t}/wifi.log" /root/shared_persistent_storage/AP_status
for phy in $(awk '!/^#/ && / phy / { gsub("\047", ""); print $3 }' /etc/config/wireless); do
  mkdir -p "/sys/class/ieee80211/${phy}"
  echo 0 > "/sys/class/ieee80211/${phy}/index"
done
EOF
# run [mode]: resets, runs the setup on stdin (not in argv, which pgrep -f
# would see), then the checker, and prints its exit status, its time and
# what it left behind
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/run' << 'EOF'
#!/bin/sh
t=/tmp/rfhs-test
"${t}/reset"
eval "$(cat)"
read -r start _ < /proc/uptime
if PATH="${t}:${PATH}" /usr/sbin/rfhs_checker ${1:-} > "${t}/out" 2>&1; then rc=0; else rc=$?; fi
read -r end _ < /proc/uptime
echo "exit ${rc}"
awk -v s="${start}" -v e="${end}" 'BEGIN { printf "ms %d\n", (e - s) * 1000 }'
sed 's/^/status /' /root/shared_persistent_storage/AP_status
if [ -f "${t}/wifi.log" ]; then sed 's/^/wifi /' "${t}/wifi.log"; fi
if [ -d /run/rfctf_status ]; then
  echo "now $(date +%s)"
  for f in /run/rfctf_status/*; do echo "rfctf ${f##*/} $(stat -c %Y "${f}")"; done
fi
sed 's/^/out /' "${t}/out"
EOF
# measure runs: CPU (from the container's cgroup) and wall time per healthy
# pass, without and with /run/rfctf_status
docker exec -i "${c}" sh -c 'cat > /tmp/rfhs-test/measure' << 'EOF'
#!/bin/sh
t=/tmp/rfhs-test
"${t}/reset"
for status_files in without with; do
  if [ "${status_files}" = with ]; then mkdir -p /run/rfctf_status; fi
  u0="$(awk '$1 == "usage_usec" { print $2 }' /sys/fs/cgroup/cpu.stat)"
  read -r w0 _ < /proc/uptime
  i=0
  while [ "${i}" -lt "${1}" ]; do
    PATH="${t}:${PATH}" /usr/sbin/rfhs_checker > /dev/null 2>&1 || echo "a pass failed"
    i=$((i + 1))
  done
  read -r w1 _ < /proc/uptime
  u1="$(awk '$1 == "usage_usec" { print $2 }' /sys/fs/cgroup/cpu.stat)"
  awk -v u="$((u1 - u0))" -v w0="${w0}" -v w1="${w1}" -v n="${1}" -v s="${status_files}" \
    'BEGIN { printf "%s /run/rfctf_status: %.1f ms CPU, %.0f ms wall per pass\n", s, u / n / 1000, (w1 - w0) * 1000 / n }'
done
EOF
docker exec "${c}" chmod 755 /tmp/rfhs-test/iwinfo /tmp/rfhs-test/ss /tmp/rfhs-test/iw /tmp/rfhs-test/wifi \
  /tmp/rfhs-test/mac80211.sh /tmp/rfhs-test/reset /tmp/rfhs-test/run /tmp/rfhs-test/measure

ssid="$(docker exec "${c}" awk '!/^#/ && / ssid / { gsub("\047", ""); print $3; exit }' /etc/config/wireless)"
phy="$(docker exec "${c}" awk '!/^#/ && / phy / { gsub("\047", ""); print $3; exit }' /etc/config/wireless)"

failures=0
out=""
# run_case mode setup: the setup runs in the container before the checker
run_case() {
  out="$(printf '%s\n' "${2}" | docker exec -i "${c}" /tmp/rfhs-test/run "${1}")"
}
has() {
  printf '%s\n' "${out}" | grep -qxF -- "${1}"
}
has_re() {
  printf '%s\n' "${out}" | grep -q -- "${1}"
}
pass() {
  printf 'PASS: %s\n' "${name}"
}
fail() {
  printf 'FAIL: %s\n' "${name}"
  printf '%s\n' "${out}" | sed 's/^/    /'
  failures=$((failures + 1))
}
drop_ssid="awk -v s='${ssid}' '\$0 == s && !done { done = 1; next } 1' \"\${t}/ssids\" > \"\${t}/ssids.new\" && mv \"\${t}/ssids.new\" \"\${t}/ssids\""
drop_110="sed -i '/ 0\\.0\\.0\\.0:110 /d' \"\${t}/sockets\""

run_case '' ''
name='a healthy pass succeeds and leaves the wifi alone'
if has 'exit 0' && has 'status Check Pass' && has 'status Service Check Pass' \
  && has 'status Checker run completed' && ! has_re '^wifi '; then
  pass
else
  fail
fi
name='a healthy pass with nothing configuring the wifi takes under a second'
if [ "$(printf '%s\n' "${out}" | sed -n 's/^ms //p')" -lt 1000 ]; then
  pass
else
  fail
fi

# shellcheck disable=SC2016 # it expands in the container
run_case '' '"${t}/mac80211.sh" > /dev/null 2>&1 & while ! pgrep -f mac80211.sh > /dev/null; do :; done'
name='a pass waits for mac80211.sh to finish'
if has 'exit 0' && has 'status mac802.11.sh is configuring interfaces...' \
  && [ "$(printf '%s\n' "${out}" | sed -n 's/^ms //p')" -ge 2000 ]; then
  pass
else
  fail
fi

run_case '' "${drop_ssid}"
name="a configured SSID that isn't running fails, names it and restarts the wifi"
if has 'exit 1' && has "status ${ssid} is configured but not running" && has 'status Check Failed' \
  && has 'wifi up' && has 'status Failures found, restarting wifi to attempt auto recovery...'; then
  pass
else
  fail
fi

# shellcheck disable=SC2016 # it expands in the container
run_case '' 'echo RFHS_TEST_EXTRA >> "${t}/ssids"'
name="a running SSID that isn't configured fails and is named"
if has 'exit 1' && has 'status RFHS_TEST_EXTRA is running but not configured???' && has 'wifi up'; then
  pass
else
  fail
fi

run_case '' "printf '\\nconfig wifi-iface\\n\\toption mode '\\''ap'\\''\\n\\toption ssid '\\''%s'\\''\\n' '${ssid}' >> /etc/config/wireless"
name='an SSID configured on two APs but running on one fails'
if has 'exit 1' && has "status ${ssid} is configured but not running"; then
  pass
else
  fail
fi

run_case '' "rm -r '/sys/class/ieee80211/${phy}'"
name='a configured phy that is missing fails'
if has 'exit 1' && has "status ${phy} is configured but missing" && has 'status Check Failed'; then
  pass
else
  fail
fi

run_case '' "${drop_110}"
name='nothing on tcp port 110 fails and the report lists the sockets, without restarting the wifi'
if has 'exit 1' && has 'status Nothing is listening on tcp port 110' && has 'status Service Check Failed' \
  && has_re '^status udp .* 0\.0\.0\.0:67 ' && has_re '^status tcp .* 0\.0\.0\.0:22 ' \
  && has 'status Check Pass' && ! has_re '^wifi '; then
  pass
else
  fail
fi

run_case '' "sed -i '/ 0\\.0\\.0\\.0:67 /d' \"\${t}/sockets\""
name='nothing on udp port 67 fails and the report lists the sockets'
if has 'exit 1' && has 'status Nothing is listening on udp port 67' \
  && has_re '^status tcp .* 0\.0\.0\.0:110 '; then
  pass
else
  fail
fi

run_case '' "sed -i 's/ 0\\.0\\.0\\.0:110 / 0.0.0.0:1100 /' \"\${t}/sockets\""
name='a listener on port 1100 does not count as port 110'
if has 'exit 1' && has 'status Nothing is listening on tcp port 110'; then
  pass
else
  fail
fi

run_case '' "${drop_ssid}; ${drop_110}"
name='two failures exit 1, not 2, which docker reserves'
if has 'exit 1'; then
  pass
else
  fail
fi

run_case '' "mkdir -p /run/rfctf_status && touch -d '2000-01-01 00:00:00' '/run/rfctf_status/${ssid}_ap_running'"
now="$(printf '%s\n' "${out}" | sed -n 's/^now //p')"
mtime="$(printf '%s\n' "${out}" | sed -n "s/^rfctf ${ssid}_ap_running //p")"
expected="$(docker exec "${c}" sh -c '/tmp/rfhs-test/reset; sed "s/\$/_ap_running/" /tmp/rfhs-test/ssids' | LC_ALL=C sort -u)"
name='each running SSID gets a status file in /run/rfctf_status, with a new mtime'
if has 'exit 0' && [ -n "${mtime}" ] && [ "${mtime}" -ge $((now - 60)) ] \
  && [ "$(printf '%s\n' "${out}" | sed -n 's/^rfctf \([^ ]*\) .*/\1/p' | LC_ALL=C sort)" = "${expected}" ]; then
  pass
else
  fail
fi

run_case bootwifi "${drop_110}"
name='bootwifi leaves out the service check'
if has 'exit 0' && ! has_re '^status Service Check'; then
  pass
else
  fail
fi

run_case bootwifi "${drop_ssid}"
name='bootwifi fails and restarts the wifi when an SSID is not running'
if has 'exit 1' && has 'wifi up'; then
  pass
else
  fail
fi

run_case excessive ''
name='excessive finds every command it needs and passes'
if has 'exit 0' && ! has_re '^status Missing'; then
  pass
else
  fail
fi

run_case excessive 'mv /usr/bin/seq /usr/bin/seq.hidden'
name='excessive fails at once and names a command a shipped script needs when it is missing'
if has 'exit 1' && has 'status Missing required command: seq (rfhs_predictable_phys)' \
  && ! has_re '^status Check ' && ! has_re '^wifi '; then
  pass
else
  fail
fi

run_case excessive "${drop_ssid}"
name='excessive fails without restarting the wifi'
if has 'exit 1' && ! has_re '^wifi '; then
  pass
else
  fail
fi

if [ -n "${runs}" ]; then
  printf 'Measuring %s healthy passes with the fakes:\n' "${runs}"
  docker exec "${c}" /tmp/rfhs-test/measure "${runs}"
fi

if [ "${failures}" -ne 0 ]; then
  printf '%s check(s) failed\n' "${failures}"
  exit 1
fi
