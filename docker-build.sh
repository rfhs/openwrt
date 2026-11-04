#!/bin/sh

set -eux

missing_tools=""
for tool in awk cat cp date docker hostname mkdir mktemp rm sha256sum sudo tee; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi

# Everything goes to a log as well, so the healthcheck's CPU numbers build up
# across builds
if [ -z "${DOCKER_BUILD_LOG:-}" ]; then
  mkdir -p build-logs
  DOCKER_BUILD_LOG="build-logs/openwrt-$(date -u +%Y%m%dT%H%M%SZ).log"
  export DOCKER_BUILD_LOG
  status="$(mktemp)"
  { if "${0}" "$@" 2>&1; then rc=0; else rc="$?"; fi; echo "${rc}" > "${status}"; } | tee "${DOCKER_BUILD_LOG}"
  exit_code="$(cat "${status}")"
  rm -f "${status}"
  exit "${exit_code}"
fi

TARBALL_FOLDER="${HOME}/development/openwrt/bin/targets/x86/64/"
# rfctf-container has the healthcheck benchmark, the game's privileges and the radios
RFCTF="${RFCTF_CONTAINER:-${HOME}/development/rfhs/rfctf-container}"
BENCH="${RFCTF}/tools/bench_healthcheck.sh"
if [ ! -x "${BENCH}" ]; then
  printf "%s not found, set RFCTF_CONTAINER to an rfctf-container checkout\n" "${BENCH}"
  exit 1
fi
DISTRO=openwrt
BUILD_VERSION_NUMBER="$(awk -F'"' '/CONFIG_VERSION_NUMBER/ {print $2}' "${TARBALL_FOLDER}/config.buildinfo" )"
BUILD_VERSION_CODE="$(awk -F'"' '/CONFIG_VERSION_CODE=/ {gsub(" ", "-"); print tolower($2)}' "${TARBALL_FOLDER}/config.buildinfo" )"
# The Dockerfile adds files/ to the tarball, so the image can be newer than it
IMAGE_VERSION="${BUILD_VERSION_NUMBER}.2"
TARBALL="rfhs-rfctf-${BUILD_VERSION_NUMBER}-${BUILD_VERSION_CODE}-x86-64-generic-rootfs.tar.gz"

#Verify checksum matches before starting
expected_sha256=$(awk '/tar\.gz/ {print $1}' "${TARBALL_FOLDER}/sha256sums")
tarball_sha256="$(sha256sum "${TARBALL_FOLDER}${TARBALL}" | awk '{print $1}')"
if [ "${expected_sha256}" != "${tarball_sha256}" ]; then
  printf "Checksum failed, aborting for safety.\n"
  exit 1
fi

cp "${TARBALL_FOLDER}${TARBALL}" .
trap 'rm -f "${TARBALL}"' EXIT

CI_REGISTRY_IMAGE=rfhs
BUILD_DATE=$(date -u +"%Y.%m.%d")

IMAGE=$DISTRO

docker build --no-cache -t \
  "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" \
  --build-arg TARBALL="${TARBALL}" \
  --build-arg BUILD_DATE="${BUILD_DATE}" \
  --build-arg VERSION="${IMAGE_VERSION}" \
  .
# Nothing is tagged or pushed unless all of these pass on the image just
# built, with both its own config and the game's. wctf-restricted is private,
# so only a host that can't push can go without the game's config.
./tests/test_image_files.sh "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}"
push=""
if [ "$(hostname)" = "Nu" ] || [ "$(hostname)" = "naga" ]; then
  push=1
fi
game="${WCTF_RESTRICTED:-${HOME}/development/rfhs/wctf-restricted}/wifi/openwrt/airkraken"
game_config="${game}/files"
test_game=""
if [ -n "${push}" ] || [ -d "${game_config}" ]; then
  test_game=1
else
  printf "No %s, so the game's config is untested and this can't push\n" "${game_config}"
fi
./tests/test_rfhs_checker.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" -m 20
if [ -n "${test_game}" ]; then
  ./tests/test_rfhs_checker.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" -m 20 \
    -w "${game_config}/etc/config/wireless"
fi
RFCTF_CONTAINER="${RFCTF}" ./tests/test_firewall.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" public
RFCTF_CONTAINER="${RFCTF}" ./tests/test_firewall.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" \
  -s tests/firewall-gateway-services restricted tests/firewall
if [ -n "${test_game}" ]; then
  RFCTF_CONTAINER="${RFCTF}" ./tests/test_firewall.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" \
    -s "${game}/gateway-services" restricted "${game_config}"
fi
# Not parallel safe: these take back every mac80211_hwsim radio
RFCTF_CONTAINER="${RFCTF}" ./tests/test_healthcheck.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" public
if [ -n "${test_game}" ]; then
  RFCTF_CONTAINER="${RFCTF}" ./tests/test_healthcheck.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" \
    restricted "${game_config}"
fi

docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
if [ -n "${push}" ]; then
  docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}"
  docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
fi
