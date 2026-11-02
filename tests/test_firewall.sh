#!/bin/sh
# Tests what openwrt's wifi networks can reach, and fails on anything else.
# Each network gets a container of its own on its VLAN, which takes a DHCP
# lease. Its tagged frames come in through the same bridge and firewall zone
# as a wifi client's, so this needs neither radios nor root. Another container
# on wan stands in for the internet, as openwrt's upstream DHCP and DNS.
#   ./tests/test_firewall.sh [-i image] public
#   ./tests/test_firewall.sh [-i image] [-s services] restricted overlay
# public tests the image's own config: every wifi network has working DHCP and
# DNS, reaches the admin page and reaches every other wifi network.
# restricted mounts overlay over the image, as the game does: every wifi
# network has working DHCP and DNS and reaches the internet, firewall rules in
# its zone reject the admin address and the admin network, and it reaches
# neither the admin network nor any other wifi network, while the admin
# network reaches it. Its gateway answers on DHCP, DNS and ping, and on
# exactly what services lists for it, one "network port/proto" a line, or
# nothing else without -s. tests/firewall is a public stand-in for the game's
# overlay, wctf-restricted/wifi/openwrt/airkraken/files, and
# tests/firewall-gateway-services its list.
# The networks, addresses and listening ports all come from the running
# router. RFCTF_CONTAINER is an rfctf-container checkout, by default
# ~/development/rfhs/rfctf-container.
set -eu

image=rfhs/openwrt:latest
services=/dev/null
while getopts i:s: opt; do
  case "${opt}" in
    i) image="${OPTARG}";;
    s) services="${OPTARG}";;
    *) exit 2;;
  esac
done
shift $((OPTIND - 1))
mode="${1:-}"
overlay="${2:-}"
if { [ "${mode}" != public ] || [ "$#" -ne 1 ] || [ "${services}" != /dev/null ]; } \
  && { [ "${mode}" != restricted ] || [ "$#" -ne 2 ]; }; then
  printf 'usage: %s [-i image] public\n       %s [-i image] [-s services] restricted overlay\n' "${0}" "${0}" >&2
  exit 2
fi
if [ ! -r "${services}" ]; then
  printf "Can't read %s\n" "${services}" >&2
  exit 2
fi
missing_tools=""
for tool in awk chmod cut docker find grep mktemp mv rm sed sha256sum sleep sort tail tr; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi
if [ "${mode}" = restricted ]; then
  if [ ! -d "${overlay}" ]; then
    printf '%s is not a directory\n' "${overlay}" >&2
    exit 2
  fi
  overlay="$(cd "${overlay}" && pwd)"
fi
# shellcheck source=/dev/null
. "${RFCTF_CONTAINER:-${HOME}/development/rfhs/rfctf-container}/startup/rfhs-helpers.sh"

router="rfhs-firewall-test-$$"
probe_image=rfhs-test/firewall-probe:latest
# Only ever on the test's internal network. dnsmasq's rebind protection strips
# the documentation ranges from answers.
internet=93.184.216.34
internet_name=example.com
work="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() {
  docker ps -aq --filter "name=^${router}" | while read -r id; do
    docker rm -f "${id}" > /dev/null 2>&1 || true
  done
  docker network rm "${router}-eth0" "${router}-eth1" > /dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT
sed -e 's/#.*//' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' -e '/^$/d' "${services}" > "${work}/services"

failed=0
pass() {
  printf 'PASS: %s\n' "${1}"
}
fail() {
  printf 'FAIL: %s\n' "${1}"
  failed=1
}
note() {
  printf 'NOTE: %s\n' "${1}"
}

# Containers on some hosts can't get out, though the host itself can
printf 'FROM alpine:3\nRUN apk add --no-cache bind-tools curl dnsmasq iproute2 nmap-ncat\n' > "${work}/probe"
if ! docker build -t "${probe_image}" - < "${work}/probe" > "${work}/probe.log" 2>&1 \
  && ! docker build --network host -t "${probe_image}" - < "${work}/probe" >> "${work}/probe.log" 2>&1; then
  cat "${work}/probe.log" >&2
  printf "Can't build %s; apk exiting with the number of packages means it can't reach Alpine's mirrors\n" "${probe_image}" >&2
  exit 1
fi
docker network create --internal "${router}-eth0" > /dev/null
docker network create --internal "${router}-eth1" > /dev/null

# These two wait for the radios, and the second holds the rest of the boot
# until every AP is up.
printf '#!/bin/sh /etc/rc.common\nSTART=18\nboot() { :; }\n' > "${work}/no-radios"
chmod 755 "${work}/no-radios"
# The kernel otherwise limits how often it refuses one source, and a port that
# isn't refused looks open.
(
  IFS='
'
  set -f
  # shellcheck disable=SC2046
  docker create --rm --no-healthcheck --network "${router}-eth0" --name "${router}" \
    --tmpfs /run:mode=0755,nosuid,nodev,nr_inodes=800k,size=20%,strictatime \
    --sysctl net.ipv4.icmp_ratelimit=0 \
    -v "${work}/no-radios:/etc/init.d/rfhs_predictable_phys:ro" \
    -v "${work}/no-radios:/etc/init.d/rfhs_wifi_fixer:ro" \
    $(if [ -n "${overlay}" ]; then openwrt_overlay_args "${overlay}"; fi) \
    $(openwrt_docker_args) "${image}" > /dev/null
)
openwrt_start "${router}" "${router}-eth1" > /dev/null

docker run -d --rm --name "${router}-internet" --network "${router}-eth1" \
  --cap-add net_admin --cap-add net_raw "${probe_image}" sleep infinity > /dev/null
wan_address="$(docker exec "${router}-internet" ip -4 -o addr show eth0 | awk '{print $4}')"
wan_address="${wan_address%/*}"
docker exec "${router}-internet" ip addr add "${internet}/32" dev lo
docker exec -d "${router}-internet" ncat -k -l "${internet}" 8080
docker exec -d "${router}-internet" dnsmasq -k --user=root --no-resolv --no-hosts --port=8081 \
  "--address=/${internet_name}/${internet}"
docker exec -d "${router}-internet" dnsmasq -k --user=root --no-resolv --no-hosts --interface=eth0 \
  "--address=/${internet_name}/${internet}" "--dhcp-range=${wan_address%.*}.100,${wan_address%.*}.200,1h" \
  "--dhcp-option=3,${wan_address}" "--dhcp-option=6,${wan_address}"

waited=0
# The game's rc.local never returns, so procd never says the boot is complete;
# uhttpd is one of the last to start.
until docker exec "${router}" sh -c 'ss -lntH | grep -q ":${1##*:} "' sh \
  "$(docker exec "${router}" uci -q get uhttpd.main.listen_https | awk '{print $1}')" 2> /dev/null; do
  if [ "${waited}" -ge 120 ]; then
    printf '%s did not finish booting\n' "${router}" >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
# wan and the other interfaces reload the firewall as they come up
sleep 10

# Each line: wifi or admin, network, zone, address, mask, device, VLAN
# shellcheck disable=SC2016
docker exec -i "${router}" sh -s > "${work}/networks" << 'EOF'
describe() {
  status="$(ifstatus "${2}")"
  address="$(printf '%s' "${status}" | jsonfilter -e '@["ipv4-address"][0].address')"
  mask="$(printf '%s' "${status}" | jsonfilter -e '@["ipv4-address"][0].mask')"
  device="$(printf '%s' "${status}" | jsonfilter -e '@.l3_device')"
  vlan=""
  for port in "/sys/class/net/${device}/brif/eth0."*; do
    if [ -e "${port}" ]; then
      vlan="${port##*.}"
    fi
  done
  zone="$(fw4 -q network "${2}" || true)"
  printf '%s %s %s %s %s %s %s\n' "${1}" "${2}" "${zone:--}" "${address:--}" "${mask:--}" "${device:--}" "${vlan:--}"
}
admin="$(uci -q get uhttpd.main.listen_https | awk '{print $1}')"
for object in $(ubus list 'network.interface.*'); do
  name="${object#network.interface.}"
  if ifstatus "${name}" | jsonfilter -e '@["ipv4-address"][*].address' | grep -qx "${admin%:*}"; then
    describe admin "${name}"
  fi
done
uci -q show wireless | sed -n 's/^wireless\..*\.network=//p' | tr -d "'" | tr ' ' '\n' | sort -u \
  | while read -r name; do
    describe wifi "${name}"
  done
EOF
admin_address="$(docker exec "${router}" uci -q get uhttpd.main.listen_https | awk '{print $1}')"
admin_port="${admin_address##*:}"
admin_address="${admin_address%:*}"
if ! grep -q '^admin ' "${work}/networks"; then
  printf 'No network has the admin page'"'"'s address, %s\n' "${admin_address}" >&2
  exit 1
fi
if ! grep -q '^wifi ' "${work}/networks"; then
  printf 'The config has no wifi networks\n' >&2
  exit 1
fi
admin_network="$(awk '$1 == "admin" {print $2}' "${work}/networks")"
admin_zone="$(awk '$1 == "admin" {print $3}' "${work}/networks")"
admin_device="$(awk '$1 == "admin" {print $6}' "${work}/networks")"
admin_subnet="$(docker exec "${router}" ip -4 route show dev "${admin_device}" proto kernel scope link | awk '{print $1; exit}')"

if docker exec "${router}" nft list table inet fw4 > "${work}/ruleset" 2> /dev/null \
  && grep -q 'chain input ' "${work}/ruleset"; then
  pass "the firewall is loaded, with $(grep -c 'chain ' "${work}/ruleset") chains"
else
  fail 'the firewall is not loaded, so nothing is filtered'
fi
while read -r kind network zone address mask device vlan; do
  if [ "${kind}" != wifi ]; then
    continue
  fi
  if [ "${mode}" = restricted ]; then
    if [ "${network}" = "${admin_network}" ]; then
      fail "wifi network ${network} is the admin network"
    elif [ "${zone}" = - ]; then
      fail "wifi network ${network} isn't in a firewall zone"
    elif [ "${zone}" = "${admin_zone}" ]; then
      fail "wifi network ${network} is in the admin zone, ${zone}"
    elif docker exec "${router}" nft list chain inet fw4 "input_${zone}" | sed 's/ comment ".*//' \
      | grep "ip daddr ${admin_address} " | grep -q -E 'reject|drop'; then
      pass "${network} has a firewall rule blocking the admin address"
    else
      fail "${network} has no firewall rule blocking the admin address, ${admin_address}"
    fi
    if [ "${zone}" != - ] && [ "${zone}" != "${admin_zone}" ]; then
      if docker exec "${router}" nft list chain inet fw4 "forward_${zone}" | sed 's/ comment ".*//' \
        | grep "ip daddr ${admin_subnet:-unknown} " | grep -q -E 'reject|drop'; then
        pass "${network} has a firewall rule blocking the admin network, ${admin_subnet}"
      else
        fail "${network} has no firewall rule blocking the admin network, ${admin_subnet:-unknown}"
      fi
    fi
  fi
  if [ "${address}" = - ] || [ "${mask}" = - ] || [ "${device}" = - ] || [ "${vlan}" = - ]; then
    fail "wifi network ${network} isn't up on a VLAN of eth0, so it can't be tested"
  fi
done < "${work}/networks"
awk '$4 != "-" && $5 != "-" && $6 != "-" && $7 != "-"' "${work}/networks" > "${work}/networks.up"
mv "${work}/networks.up" "${work}/networks"
docker exec "${router}" ip -6 -o addr show scope global | awk '{print $2, $4}' > "${work}/ipv6"
if [ -s "${work}/ipv6" ]; then
  while read -r device address; do
    fail "${device} has the routable IPv6 address ${address}, which this test doesn't probe"
  done < "${work}/ipv6"
else
  pass 'the router has no routable IPv6 address, and link-local addresses stop at their network'
fi

# probe_name network: the container on that network
probe_name() {
  printf '%s-%s' "${router}" "${1}"
}

# Each line of leases: network, its router's address, the probe's address
: > "${work}/leases"
sort -u -k2,2 "${work}/networks" > "${work}/unique"
while read -r _ network _ address mask _ vlan; do
  probe="$(probe_name "${network}")"
  docker run -d --rm --name "${probe}" --network "${router}-eth0" \
    --cap-add net_admin --cap-add net_raw "${probe_image}" sleep infinity > /dev/null
  # Without the address on eth0, all it sends goes through its VLAN to the
  # router.
  docker exec "${probe}" sh -c "
    ip link add link eth0 name eth0.${vlan} type vlan id ${vlan}
    ip addr flush dev eth0
    ip link set eth0.${vlan} up
  "
  if docker exec "${probe}" udhcpc -i "eth0.${vlan}" -n -q -t 10 -T 1 > /dev/null 2>&1; then
    pass "${network} gets a DHCP lease"
    if [ "$(docker exec "${probe}" sh -c "ip route show default | awk '{print \$3}'")" != "${address}" ]; then
      fail "${network}'s DHCP lease doesn't make ${address} its gateway"
    fi
  else
    fail "${network} gets no DHCP lease"
    docker exec "${probe}" sh -c "
      ip addr add ${address%.*}.50/${mask} dev eth0.${vlan}
      ip route replace default via ${address}
    "
  fi
  leased="$(docker exec "${probe}" ip -4 -o addr show "eth0.${vlan}" | awk '{print $4}')"
  printf '%s %s %s\n' "${network}" "${address}" "${leased%/*}" >> "${work}/leases"
  docker exec -d "${probe}" ncat -k -l 8080
  # Without --interface, dnsmasq ignores queries from other subnets, which
  # would look blocked.
  docker exec -d "${probe}" dnsmasq -k --user=root --no-resolv --no-hosts --port=8081 \
    "--interface=eth0.${vlan}" "--address=/${internet_name}/${internet}"
done < "${work}/unique"

# Each line of targets: network, address, proto, port. What the router listens
# on comes with what every network's probe listens on; the probes' udp port
# is DNS, so no answer there means it's blocked.
docker exec "${router}" ss -lntuH | awk '{print $1, $5}' \
  | sed -E 's/^(tcp|udp) (.*):([0-9]+)$/\1 \2 \3/' \
  | grep -v -E ' (127\.|\[::1\]|\[fe80:)' > "${work}/listeners"
while read -r network address leased; do
  printf '%s %s icmp 0\n' "${network}" "${address}"
  while read -r proto listener port; do
    case "${listener}" in
      "${address}" | 0.0.0.0 | '*' | '[::]') printf '%s %s %s %s\n' "${network}" "${address}" "${proto}" "${port}";;
    esac
  done < "${work}/listeners"
  printf '%s %s host-tcp 8080\n%s %s host-dns 8081\n%s %s host-icmp 0\n' \
    "${network}" "${leased}" "${network}" "${leased}" "${network}" "${leased}"
done < "${work}/leases" | sort -u > "${work}/targets"
printf 'internet %s host-tcp 8080\ninternet %s host-dns 8081\ninternet %s host-icmp 0\n' \
  "${internet}" "${internet}" "${internet}" > "${work}/internet"

# Prints each line it reads whose target is open, and "done" at the end. A
# refused udp port is shut, and a silent one could be dropped or could have
# taken the packet, so it counts as open.
# shellcheck disable=SC2016
probe_script='
while read -r network address proto port; do
  open=""
  case "${proto}" in
    tcp | host-tcp) ncat -z -w 2 "${address}" "${port}" > /dev/null 2>&1 < /dev/null && open=1;;
    icmp | host-icmp) ping -c 2 -W 1 "${address}" > /dev/null 2>&1 < /dev/null && open=1;;
    host-dns) dig "@${address}" -p "${port}" +short +time=1 +tries=2 example.com A 2> /dev/null | grep -q "^[0-9]" && open=1;;
    udp) printf x | ncat -u -i 1 "${address}" "${port}" > /dev/null 2>&1 && open=1;;
  esac
  if [ -n "${open}" ]; then
    printf "%s %s %s %s\n" "${network}" "${address}" "${proto}" "${port}"
  fi
done
printf "done\n"
'

admin_page="$(docker exec "$(probe_name "${admin_network}")" \
  curl -skf -m 5 "https://${admin_address}:${admin_port}/" | sha256sum | cut -d' ' -f1)"
empty="$(printf '' | sha256sum | cut -d' ' -f1)"
if [ "${admin_page}" != "${empty}" ]; then
  pass "the admin network loads the admin page, https://${admin_address}:${admin_port}/"
else
  fail "the admin network can't load https://${admin_address}:${admin_port}/"
fi

while read -r network address _; do
  probe="$(probe_name "${network}")"
  if grep -q "^wifi ${network} " "${work}/networks"; then
    (
      grep -v "^${network} " "${work}/targets" | docker exec -i "${probe}" sh -c "${probe_script}" > "${work}/open.${network}"
      grep "^${network} ${address} " "${work}/targets" | docker exec -i "${probe}" sh -c "${probe_script}" > "${work}/own.${network}"
      docker exec -i "${probe}" sh -c "${probe_script}" < "${work}/internet" > "${work}/internet.${network}"
    ) &
  elif [ "${network}" = "${admin_network}" ]; then
    grep -v "^${network} " "${work}/targets" \
      | docker exec -i "${probe}" sh -c "${probe_script}" > "${work}/admin-reach" &
  fi
done < "${work}/leases"
wait

# dns_query probe server name: sets dns_status to what the server says, empty
# if it never replies, and dns_answer to the first address. The game's
# rc.local restarts dnsmasq late in the boot, so one miss doesn't mean it's down.
dns_query() {
  dns_status=""
  dns_answer=""
  tries=0
  while [ -z "${dns_status}" ] && [ "${tries}" -lt 10 ]; do
    reply="$(docker exec "${1}" dig "@${2}" +time=1 +tries=1 "${3}" A 2> /dev/null || true)"
    dns_status="$(printf '%s\n' "${reply}" | sed -n 's/.*status: \([A-Z]*\),.*/\1/p')"
    dns_answer="$(printf '%s\n' "${reply}" | awk '/^[^;]/ && $4 == "A" {print $5; exit}')"
    tries=$((tries + 1))
  done
}

# The address and port of a target, as people write it
target() {
  case "${2}" in
    icmp | host-icmp) printf '%s (ping)' "${1}";;
    host-dns) printf '%s:%s/udp' "${1}" "${3}";;
    host-tcp) printf '%s:%s/tcp' "${1}" "${3}";;
    *) printf '%s:%s/%s' "${1}" "${3}" "${2}";;
  esac
}

first="$(awk '$1 == "wifi" {print $2, $6; exit}' "${work}/networks")"
first_network="${first% *}"
first_device="${first#* }"
first_probe="$(probe_name "${first_network}")"
second="$(awk -v first="${first_network}" '$1 == "wifi" && $2 != first {print $2, $6; exit}' "${work}/networks")"
local_domain="$(docker exec "${router}" uci -q get 'dhcp.@dnsmasq[0].domain' || printf lan)"
ubus_call='{"jsonrpc":"2.0","id":1,"method":"list","params":[]}'
while read -r network address _; do
  if ! grep -q "^wifi ${network} " "${work}/networks"; then
    continue
  fi
  probe="$(probe_name "${network}")"
  if ! tail -n 1 "${work}/open.${network}" | grep -qx 'done' \
    || ! tail -n 1 "${work}/own.${network}" | grep -qx 'done'; then
    fail "the probe on ${network} didn't finish"
    continue
  fi
  if ! grep -q "^${network} ${address} icmp " "${work}/own.${network}"; then
    fail "${network} can't ping its own gateway, so its other results prove nothing"
  fi

  dns_query "${probe}" "${address}" "rfhs-test.${local_domain}"
  case "${dns_status}" in
    NOERROR | NXDOMAIN) pass "${network}'s gateway answers DNS for local names";;
    '') fail "${network}'s DNS is down: ${address} doesn't reply";;
    *) fail "${network}'s DNS is broken: ${address} says ${dns_status} for a local name";;
  esac
  dns_query "${probe}" "${address}" "${internet_name}"
  if [ "${dns_answer}" = "${internet}" ]; then
    pass "${network} resolves internet names through its gateway"
  elif [ -n "${dns_status}" ]; then
    fail "${network}'s DNS has no upstream: ${address} says ${dns_status} for ${internet_name}"
  else
    fail "${network}'s DNS is down: ${address} doesn't reply for ${internet_name}"
  fi

  if [ "${mode}" = public ]; then
    if docker exec "${probe}" curl -skf -m 5 "https://${admin_address}:${admin_port}/" 2> /dev/null \
      | sha256sum | cut -d' ' -f1 | grep -qx "${admin_page}"; then
      pass "${network} loads the admin page"
    else
      fail "${network} can't load the admin page"
    fi
    missing=""
    while read -r owner to proto port; do
      case "${proto}" in
        icmp | host-*)
          if ! grep -q "^${owner} ${to} ${proto} ${port}\$" "${work}/open.${network}"; then
            fail "${network} can't reach ${owner}: $(target "${to}" "${proto}" "${port}")"
            missing=1
          fi
          ;;
      esac
    done << EOF
$(grep -v "^${network} " "${work}/targets" || true)
EOF
    if [ -z "${second}" ]; then
      note "${network} is the only wifi network, so there is no other for it to reach"
    elif [ -z "${missing}" ]; then
      pass "${network} reaches every other wifi network"
    fi
    continue
  fi

  reaches_admin=""
  reaches_other=""
  while read -r owner to proto port; do
    if [ "${owner}" = "${admin_network}" ]; then
      fail "${network} reaches the admin network: $(target "${to}" "${proto}" "${port}")"
      reaches_admin=1
    elif [ "${owner}" != 'done' ]; then
      fail "${network} reaches ${owner}: $(target "${to}" "${proto}" "${port}")"
      reaches_other=1
    fi
  done < "${work}/open.${network}"
  if [ -z "${reaches_admin}" ]; then
    pass "${network} can't reach the admin network"
  fi
  if [ -z "${reaches_other}" ]; then
    pass "${network} can't reach the other wifi networks"
  fi

  no_internet=""
  while read -r owner to proto port; do
    if ! grep -q "^internet ${to} ${proto} " "${work}/internet.${network}"; then
      fail "${network} can't reach the internet: $(target "${to}" "${proto}" "${port}")"
      no_internet=1
    fi
  done < "${work}/internet"
  if [ -z "${no_internet}" ]; then
    pass "${network} reaches the internet"
  fi

  own=""
  while read -r owner to proto port; do
    case "${owner}:${proto}" in
      done:*) continue;;
      *:icmp) own="${own} ping"; continue;;
      *:tcp)
        for scheme in http https; do
          url="${scheme}://${to}:${port}"
          if docker exec "${probe}" curl -sk -m 3 -X POST -d "${ubus_call}" "${url}/ubus" 2> /dev/null | grep -q '"jsonrpc"'; then
            fail "${network} gets the admin API, ${url}/ubus"
          fi
          page="$(docker exec "${probe}" curl -skf -m 3 "${url}/" 2> /dev/null | sha256sum | cut -d' ' -f1 || true)"
          if [ "${page}" = "${admin_page}" ]; then
            fail "${network} gets the admin page at ${url}/"
          fi
        done
        ;;
    esac
    own="${own} ${port}/${proto}"
    case "${proto}/${port}" in
      tcp/53 | udp/53 | udp/67) ;;
      *)
        if ! grep -qx "${network} ${port}/${proto}" "${work}/services"; then
          fail "${network}'s gateway answers on ${port}/${proto}, which ${services} doesn't list for it"
        fi
        ;;
    esac
  done < "${work}/own.${network}"
  while read -r _ service; do
    if [ -n "${service}" ] && ! grep -qx "${network} ${address} ${service#*/} ${service%/*}" "${work}/own.${network}"; then
      fail "${network}'s gateway doesn't answer on ${service}, which ${services} lists for it"
    fi
  done << EOF
$(grep "^${network} " "${work}/services" || true)
EOF
  note "${network}'s gateway answers it on:${own:- nothing}"
done < "${work}/leases"
while read -r network _; do
  if ! grep -q "^wifi ${network} " "${work}/networks"; then
    fail "${services} lists ${network}, which isn't a wifi network"
  fi
done < "${work}/services"

if [ -f "${work}/admin-reach" ]; then
  if ! tail -n 1 "${work}/admin-reach" | grep -qx 'done'; then
    fail "the probe on ${admin_network} didn't finish"
  else
    missing=""
    while read -r owner to proto port; do
      case "${proto}" in
        icmp | host-*)
          if grep -q "^wifi ${owner} " "${work}/networks" \
            && ! grep -q "^${owner} ${to} ${proto} ${port}\$" "${work}/admin-reach"; then
            fail "${admin_network} can't reach ${owner}: $(target "${to}" "${proto}" "${port}")"
            missing=1
          fi
          ;;
      esac
    done < "${work}/targets"
    if [ -z "${missing}" ]; then
      pass "${admin_network} reaches every wifi network"
    fi
  fi
fi

# A test that can't fail proves nothing: change the firewall in this throwaway
# router and check that the probes see it.
if [ "${mode}" = public ]; then
  docker exec "${router}" nft insert rule inet fw4 input iifname "\"${first_device}\"" \
    ip daddr "${admin_address}" tcp dport "${admin_port}" reject
  printf '%s %s tcp %s\n' "${admin_network}" "${admin_address}" "${admin_port}" \
    | docker exec -i "${first_probe}" sh -c "${probe_script}" > "${work}/hole"
  if grep -q "^${admin_network} " "${work}/hole"; then
    fail "self-check: with a rule added blocking the admin page from ${first_network}, the test still sees it get through, so its other results prove nothing"
  else
    pass "self-check: with a rule added blocking the admin page from ${first_network}, the test sees it blocked"
  fi
else
  docker exec "${router}" nft insert rule inet fw4 input iifname "\"${first_device}\"" \
    ip daddr "${admin_address}" tcp dport "${admin_port}" accept
  printf '%s %s tcp %s\n' "${admin_network}" "${admin_address}" "${admin_port}" \
    | docker exec -i "${first_probe}" sh -c "${probe_script}" > "${work}/hole"
  if grep -q "^${admin_network} " "${work}/hole"; then
    pass "self-check: with a rule added letting ${first_network} reach the admin page, the test sees it get through"
  else
    fail "self-check: with a rule added letting ${first_network} reach the admin page, the test doesn't see it, so its other results prove nothing"
  fi
  if [ -n "${second}" ]; then
    second_network="${second% *}"
    second_device="${second#* }"
    docker exec "${router}" nft insert rule inet fw4 forward iifname "\"${first_device}\"" \
      oifname "\"${second_device}\"" accept
    awk -v network="${second_network}" '$1 == network {print $1, $3, "host-tcp", 8080}' "${work}/leases" \
      | docker exec -i "${first_probe}" sh -c "${probe_script}" > "${work}/hole"
    if grep -q "^${second_network} " "${work}/hole"; then
      pass "self-check: with a rule added letting ${first_network} reach ${second_network}, the test sees it get through"
    else
      fail "self-check: with a rule added letting ${first_network} reach ${second_network}, the test doesn't see it, so its other results prove nothing"
    fi
  fi
fi
if [ -f "${work}/admin-reach" ]; then
  docker exec "${router}" nft insert rule inet fw4 forward iifname "\"${admin_device}\"" \
    oifname "\"${first_device}\"" reject
  awk -v network="${first_network}" '$1 == network {print $1, $3, "host-tcp", 8080}' "${work}/leases" \
    | docker exec -i "$(probe_name "${admin_network}")" sh -c "${probe_script}" > "${work}/hole"
  if grep -q "^${first_network} " "${work}/hole"; then
    fail "self-check: with a rule added blocking ${admin_network} from ${first_network}, the test still sees it get through, so its other results prove nothing"
  else
    pass "self-check: with a rule added blocking ${admin_network} from ${first_network}, the test sees it blocked"
  fi
fi

if [ "${failed}" -ne 0 ]; then
  printf 'FAILED: the %s config does not do what it should\n' "${mode}"
fi
exit "${failed}"
