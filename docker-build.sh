#!/bin/sh

set -eux

missing_tools=""
for tool in awk cp date docker hostname rm sha256sum sleep sudo; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
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
IMAGE_VERSION="${BUILD_VERSION_NUMBER}.1"
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
./tests/test_image_files.sh "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}"
# Nothing pushes unless all of these pass. wctf-restricted is private, so only
# a host that can't push can go without the game's config.
push=""
if [ "$(hostname)" = "Nu" ] || [ "$(hostname)" = "naga" ]; then
  push=1
fi
game_config="${WCTF_RESTRICTED:-${HOME}/development/rfhs/wctf-restricted}/wifi/openwrt/airkraken/files"
RFCTF_CONTAINER="${RFCTF}" ./tests/test_firewall.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" public
RFCTF_CONTAINER="${RFCTF}" ./tests/test_firewall.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" restricted tests/firewall
if [ -n "${push}" ] || [ -d "${game_config}" ]; then
  RFCTF_CONTAINER="${RFCTF}" ./tests/test_firewall.sh -i "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" restricted "${game_config}"
else
  printf "No %s, so the game's config is untested and this can't push\n" "${game_config}"
fi

## You know what all the cool kids like?  CI!  Time to test like a boss
CONTAINER_NAME="${CI_REGISTRY_IMAGE}-${IMAGE}-ci"
if [ -n "$(docker ps --filter name="${CONTAINER_NAME}" --format '{{ .ID }}' )" ]; then
  echo "Found existing ${CONTAINER_NAME} container... QUITTING"
  exit 1
fi

# Start the container
# The game's privileges, from rfctf-container; docker's own healthcheck runs
# would land in the benchmark's windows
# shellcheck source=/dev/null
. "${RFCTF}/startup/rfhs-helpers.sh"
(
  IFS='
'
  set -f
  # shellcheck disable=SC2046
  docker run -d --rm --no-healthcheck --network none --name "${CONTAINER_NAME}" \
    --tmpfs /run:mode=0755,nosuid,nodev,nr_inodes=800k,size=20%,strictatime $(openwrt_docker_args) \
    "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}"
)
  #$(if [ -d '/home/zero/development/rfhs/wctf-restricted' ]; then find '/home/zero/development/rfhs/wctf-restricted/wifi/openwrt/airkraken/files' -type f -exec printf "-v %s:%s\n" "{}" "{}" \; | sed 's#:/home/zero/development/rfhs/wctf-restricted/wifi/openwrt/airkraken/files#:#;s#$#:ro#'; fi) \
# Give it radios
sudo "${RFCTF}/tools/give_hwsim_radios.sh" "${CONTAINER_NAME}" 8
printf 'Sleeping for 30 seconds so openwrt can boot\n'
sleep 30
if "${BENCH}" -t 100 "${CONTAINER_NAME}" \
  && docker exec "${CONTAINER_NAME}" /usr/sbin/rfhs_checker excessive; then
  docker stop "${CONTAINER_NAME}"
  # Not parallel safe: this takes the radios from anything else using them
  sudo modprobe -r mac80211_hwsim
  docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  if [ -n "${push}" ]; then
    docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${IMAGE_VERSION}"
    docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  fi
  exit_code=0
else
  printf "rfhs_checker failed!\n"
  printf "%s/%s:%s is still running for your debugging pleasure\n" "${CI_REGISTRY_IMAGE}" "${IMAGE}" "${IMAGE_VERSION}"
  exit_code=1
fi
exit "${exit_code}"
