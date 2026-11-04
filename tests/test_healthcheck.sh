#!/bin/sh
# Boots the image as the game does, with mac80211_hwsim radios, and needs its
# healthcheck to pass. A first container runs rfctf-container's
# tools/bench_healthcheck.sh, which fails on a failing pass or a median pass
# over 100 ms and reports the CPU, and rfhs_checker excessive. A second runs
# docker's own HEALTHCHECK, as the game does, and has to turn healthy.
#   ./tests/test_healthcheck.sh -i image public
#   ./tests/test_healthcheck.sh -i image restricted overlay
# public boots the image's own config; restricted mounts overlay over it, as
# rfhs-container-init mounts the game's. It needs sudo for the radios, and
# takes back every mac80211_hwsim radio when it finishes, so nothing else may
# be using them. A container that fails is left running for debugging.
# RFCTF_CONTAINER is an rfctf-container checkout, by default
# ~/development/rfhs/rfctf-container.
set -eu

image=""
while getopts i: opt; do
  case "${opt}" in
    i) image="${OPTARG}";;
    *) exit 2;;
  esac
done
shift $((OPTIND - 1))
mode="${1:-}"
overlay="${2:-}"
if [ -z "${image}" ] || { { [ "${mode}" != public ] || [ "$#" -ne 1 ]; } \
  && { [ "${mode}" != restricted ] || [ "$#" -ne 2 ]; }; }; then
  printf 'usage: %s -i image public\n       %s -i image restricted overlay\n' "${0}" "${0}" >&2
  exit 2
fi
missing_tools=""
for tool in awk docker sleep sudo; do
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
rfctf="${RFCTF_CONTAINER:-${HOME}/development/rfhs/rfctf-container}"
bench="${rfctf}/tools/bench_healthcheck.sh"
if [ ! -x "${bench}" ]; then
  printf '%s not found, set RFCTF_CONTAINER to an rfctf-container checkout\n' "${bench}" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${rfctf}/startup/rfhs-helpers.sh"

name="rfhs-healthcheck-test-$$"
# rfctf-container's startup/01_openwrt.start gives the game's openwrt phy0 to phy9
radios=10
# Each "Interval StartPeriod Retries", in seconds
# shellcheck disable=SC2016
timing="$(docker image inspect -f '{{with .Config.Healthcheck}}{{.Interval}} {{.StartPeriod}} {{.Retries}}{{end}}' "${image}" \
  | awk '
    function seconds(d,    n, s) {
      s = 0
      while (match(d, /^[0-9.]+(h|ms|m|s)/)) {
        n = substr(d, 1, RLENGTH)
        d = substr(d, RLENGTH + 1)
        if (n ~ /ms$/) s += n / 1000
        else if (n ~ /h$/) s += n * 3600
        else if (n ~ /m$/) s += n * 60
        else s += n
      }
      return int(s)
    }
    NF == 3 { print seconds($1), seconds($2), $3 }')"
if [ -z "${timing}" ]; then
  printf '%s has no HEALTHCHECK\n' "${image}" >&2
  exit 1
fi

docker network create --internal "${name}-eth0" > /dev/null
docker network create --internal "${name}-eth1" > /dev/null

# boot container [docker create option...]: creates the container as
# rfhs-container-init does, starts it and gives it the radios
boot() {
  container="${1}"
  shift
  (
    IFS='
'
    set -f
    # shellcheck disable=SC2046
    docker create --rm --network "${name}-eth0" --name "${container}" \
      --tmpfs /run:mode=0755,nosuid,nodev,nr_inodes=800k,size=20%,strictatime \
      "$@" \
      $(if [ -n "${overlay}" ]; then openwrt_overlay_args "${overlay}"; fi) \
      $(openwrt_docker_args) "${image}" > /dev/null
  )
  openwrt_start "${container}" "${name}-eth1" > /dev/null
  sudo "${rfctf}/tools/give_hwsim_radios.sh" "${container}" "${radios}"
}
# left container: leaves it running and fails
left() {
  printf 'FAILED: the %s config is not healthy; %s is still running for debugging\n' "${mode}" "${1}"
  exit 1
}

# docker's own runs of the healthcheck would land in the benchmark's windows
c="${name}-bench"
boot "${c}" --no-healthcheck
printf 'Sleeping for 30 seconds so openwrt can boot\n'
sleep 30
if ! "${bench}" -t 100 "${c}"; then
  left "${c}"
fi
if docker exec "${c}" /usr/sbin/rfhs_checker excessive; then
  printf 'PASS: rfhs_checker excessive\n'
else
  left "${c}"
fi
docker stop "${c}" > /dev/null
# Fresh radios for the next container, with the names they start with
sudo modprobe -r mac80211_hwsim

c="${name}-docker"
boot "${c}"
read -r interval start_period retries << EOF
${timing}
EOF
# Every check of the start period can fail, then retries more
limit=$((start_period + (retries + 1) * interval + 30))
printf "Waiting up to %ss for docker's healthcheck, every %ss\n" "${limit}" "${interval}"
waited=0
while true; do
  if ! status="$(docker inspect -f '{{.State.Health.Status}}' "${c}" 2> /dev/null)"; then
    printf '%s stopped before its healthcheck turned healthy\n' "${c}"
    exit 1
  fi
  if [ "${status}" = healthy ]; then
    break
  fi
  if [ "${status}" = unhealthy ] || [ "${waited}" -ge "${limit}" ]; then
    printf "FAIL: docker's healthcheck is %s after %ss; the last check's AP_status:\n" "${status}" "${waited}"
    docker exec "${c}" cat /root/shared_persistent_storage/AP_status || true
    left "${c}"
  fi
  sleep 5
  waited=$((waited + 5))
done
printf "PASS: docker's healthcheck is healthy after %ss\n" "${waited}"
docker stop "${c}" > /dev/null
sudo modprobe -r mac80211_hwsim
docker network rm "${name}-eth0" "${name}-eth1" > /dev/null
