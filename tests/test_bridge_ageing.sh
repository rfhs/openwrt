#!/bin/sh
# Measures what ageing_time 0 on openwrt's bridges changes, so clients sharing
# a MAC can be weighed against flooding. It starts the image unprivileged with
# a config overlay and adds three docker networks as ports of a wifi network's
# bridge, standing in for its APs, with a client on each. It needs neither
# radios nor root, and prints the same measurements with the bridge learning,
# with ageing_time 0 and learning again.
#   ./tests/test_bridge_ageing.sh [-i image] [overlay]
# overlay defaults to tests/firewall. RFCTF_CONTAINER is an rfctf-container
# checkout, by default ~/development/rfhs/rfctf-container.
set -eu

image=rfhs/openwrt:latest
while getopts i: opt; do
  case "${opt}" in
    i) image="${OPTARG}";;
    *) exit 2;;
  esac
done
shift $((OPTIND - 1))
here="$(cd "$(dirname "${0}")" && pwd)"
overlay="${1:-${here}/firewall}"
if [ ! -d "${overlay}" ]; then
  printf '%s is not a directory\n' "${overlay}" >&2
  exit 2
fi
overlay="$(cd "${overlay}" && pwd)"
missing_tools=""
for tool in awk chmod date docker grep mktemp rm sleep; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${RFCTF_CONTAINER:-${HOME}/development/rfhs/rfctf-container}/startup/rfhs-helpers.sh"

router="rfhs-ageing-test-$$"
probe_image=rfhs-test/ageing-probe:latest
ports="a b c"
work="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() {
  docker ps -aq --filter "name=^${router}" | while read -r id; do
    docker rm -f "${id}" > /dev/null 2>&1 || true
  done
  for network in eth0 eth1 ${ports}; do
    docker network rm "${router}-${network}" > /dev/null 2>&1 || true
  done
  rm -rf "${work}"
}
trap cleanup EXIT

printf 'FROM alpine:3\nRUN apk add --no-cache iproute2 nmap-ncat tcpdump\n' > "${work}/probe"
if ! docker build -t "${probe_image}" - < "${work}/probe" > "${work}/probe.log" 2>&1 \
  && ! docker build --network host -t "${probe_image}" - < "${work}/probe" >> "${work}/probe.log" 2>&1; then
  cat "${work}/probe.log" >&2
  exit 1
fi
for network in eth0 eth1 ${ports}; do
  docker network create --internal "${router}-${network}" > /dev/null
done

printf '#!/bin/sh /etc/rc.common\nSTART=18\nboot() { :; }\n' > "${work}/no-radios"
chmod 755 "${work}/no-radios"
(
  IFS='
'
  set -f
  # shellcheck disable=SC2046
  docker create --rm --no-healthcheck --network "${router}-eth0" --name "${router}" \
    --tmpfs /run:mode=0755,nosuid,nodev,nr_inodes=800k,size=20%,strictatime \
    -v "${work}/no-radios:/etc/init.d/rfhs_predictable_phys:ro" \
    -v "${work}/no-radios:/etc/init.d/rfhs_wifi_fixer:ro" \
    $(openwrt_overlay_args "${overlay}") $(openwrt_docker_args) "${image}" > /dev/null
)
openwrt_start "${router}" "${router}-eth1" > /dev/null
waited=0
until docker exec "${router}" sh -c 'ss -lntH | grep -q ":443 "' 2> /dev/null; do
  if [ "${waited}" -ge 120 ]; then
    printf '%s did not finish booting\n' "${router}" >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
sleep 10

network="$(docker exec "${router}" sh -c "uci -q show wireless | sed -n 's/^wireless\..*\.network=//p' | tr -d \"'\" | sort -u | head -n 1")"
bridge="br-${network}"
gateway="$(docker exec "${router}" sh -c "ifstatus ${network} | jsonfilter -e '@[\"ipv4-address\"][0].address'")"
prefix="${gateway%.*}"
printf 'Bridge %s, %s, with a client on each of three ports\n' "${bridge}" "${gateway}"

# ethN in docker's order, as each goes on after the container has started
port_number=2
for port in ${ports}; do
  docker network connect "${router}-${port}" "${router}"
  docker exec "${router}" sh -c "
    ip addr flush dev eth${port_number}
    ip link set eth${port_number} master ${bridge}
  "
  port_number=$((port_number + 1))
done

client_number=61
for port in ${ports}; do
  docker run -d --rm --name "${router}-${port}" --network "${router}-${port}" \
    --cap-add net_admin --cap-add net_raw "${probe_image}" sleep infinity > /dev/null
  docker exec "${router}-${port}" sh -c "
    ip addr flush dev eth0
    ip addr add ${prefix}.${client_number}/24 dev eth0
    ip route add default via ${gateway}
  "
  client_number=$((client_number + 1))
done
b_mac="$(docker exec "${router}-b" cat /sys/class/net/eth0/address)"
docker exec -d "${router}-b" ncat -k -l 9000 --recv-only
sleep 3

# ping_result from to count interval: "loss%, average ms"
ping_result() {
  docker exec "${router}-${1}" ping -q -c "${3}" -i "${4}" -W 1 "${2}" 2>&1 \
    | awk -F'[ /]+' '/packet loss/ {for (i = 1; i <= NF; i++) if ($i ~ /%$/) loss = $i}
      /^rtt|^round-trip/ {avg = $(NF - 2)} END {print (loss == "" ? "?" : loss) ", " (avg == "" ? "-" : avg) " ms"}'
}

# sniff filter seconds: captures what the bridge sends out c's port. Not on c,
# as docker's bridge on that network learns addresses too, and drops frames
# for ones it has seen come from the router.
sniff() {
  docker exec -d "${router}" sh -c "timeout ${2} tcpdump -i eth4 -n -l '${1}' > /tmp/sniffed 2> /tmp/sniff.log"
  sleep 1
}

# sniffed: the frames captured
sniffed() {
  docker exec "${router}" sh -c 'wc -l < /tmp/sniffed'
}

# measure label: prints what the bridge does as it stands
measure() {
  printf '\n%s (ageing_time %s)\n' "${1}" \
    "$(docker exec "${router}" cat "/sys/class/net/${bridge}/bridge/ageing_time")"
  docker exec "${router}-a" ping -c 3 -i 0.2 -W 1 "${prefix}.62" > /dev/null 2>&1 || true
  printf '  a to b, ping, 50/s:              %s\n' "$(ping_result a "${prefix}.62" 200 0.02)"
  printf '  a to gateway, ping, 50/s:        %s\n' "$(ping_result a "${gateway}" 200 0.02)"

  sniff 'arp' 6
  docker exec "${router}-a" ip neigh flush all
  docker exec "${router}-a" ping -c 2 -i 0.2 -W 1 "${prefix}.62" > /dev/null 2>&1 || true
  sleep 6
  printf '  broadcasts out c'"'"'s port:          %s frames, so the capture works\n' "$(sniffed)"

  sniff "ip and host ${prefix}.61 and host ${prefix}.62" 8
  ping_result a "${prefix}.62" 25 0.2 > /dev/null
  sleep 3
  printf '  a to b, ping, 5/s, out c'"'"'s port:  %s of 50 frames\n' "$(sniffed)"

  sniff "tcp and host ${prefix}.61 and host ${prefix}.62" 6
  started="$(date +%s%N)"
  docker exec "${router}-a" sh -c "head -c 100000000 /dev/zero | ncat --send-only ${prefix}.62 9000"
  finished="$(date +%s%N)"
  sleep 6
  printf '  a to b, 100 MB over tcp:         %s ms, %s frames out c'"'"'s port\n' \
    "$(((finished - started) / 1000000))" "$(sniffed)"

  docker exec "${router}-a" ping -c 2 -i 0.2 -W 1 "${prefix}.62" > /dev/null 2>&1 || true
  printf '  addresses the bridge has now:    %s\n' \
    "$(docker exec "${router}" bridge fdb show br "${bridge}" | grep -c -v -E 'permanent|33:33|01:00:5e' || true)"

  docker exec "${router}-c" sh -c "
    ip link set eth0 down
    ip link set eth0 address ${b_mac}
    ip link set eth0 up
    ip route replace default via ${gateway}
  "
  docker exec -d "${router}-c" sh -c "ping -c 16 -i 1 -W 1 ${gateway} > /dev/null 2>&1"
  sleep 2
  printf '  a to b, b has c'"'"'s MAC, c at 1/s:  %s\n' "$(ping_result a "${prefix}.62" 50 0.2)"
  sleep 5
  docker exec "${router}-c" sh -c "
    ip link set eth0 down
    ip link set eth0 address 02:42:ac:11:00:63
    ip link set eth0 up
    ip route replace default via ${gateway}
  "
  docker exec "${router}-a" ip neigh flush all
  docker exec "${router}-b" ip neigh flush all
  docker exec "${router}-c" ip neigh flush all
  docker exec "${router}-b" ping -c 2 -i 0.2 -W 1 "${gateway}" > /dev/null 2>&1 || true
  sleep 2
}

measure 'Learning'

docker exec "${router}" sh -c "
  for i in \$(ip link show type bridge | awk -F: '/up/ {print \$2}'); do
    ip link set \"\${i}\" type bridge ageing_time 0
  done
"
measure 'Not learning'

docker exec "${router}" ip link set "${bridge}" type bridge ageing_time 30000
sleep 2
measure 'Learning again'
