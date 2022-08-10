#!/bin/sh

set -eux

TARBALL_FOLDER="${HOME}/development/openwrt/bin/targets/x86/64/"
DISTRO=openwrt
BUILD_VERSION_NUMBER="$(awk -F'"' '/CONFIG_VERSION_NUMBER/ {print $2}' "${TARBALL_FOLDER}/../../../../.config" )"
BUILD_VERSION_CODE="$(awk -F'"' '/CONFIG_VERSION_CODE=/ {gsub(" ", "-"); print tolower($2)}' "${TARBALL_FOLDER}/../../../../.config" )"
TARBALL="rfhs-rfctf-${BUILD_VERSION_NUMBER}-${BUILD_VERSION_CODE}-x86-64-generic-rootfs.tar.gz"

#Verify checksum matches before starting
expected_sha256=$(awk '/tar\.gz/ {print $1}' "${TARBALL_FOLDER}/sha256sums")
tarball_sha256="$(sha256sum ${TARBALL_FOLDER}${TARBALL} | awk '{print $1}')"
if [ "${expected_sha256}" != "${tarball_sha256}" ]; then
  printf "Checksum failed, aborting for safety.\n"
  exit 1
fi

cp "${TARBALL_FOLDER}${TARBALL}" .

CI_REGISTRY_IMAGE=rfhs
BUILD_DATE=$(date -u +"%Y.%m.%d")

IMAGE=$DISTRO

docker build -t "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}" \
    --build-arg TARBALL="${TARBALL}" \
    --build-arg BUILD_DATE="${BUILD_DATE}" \
    --build-arg VERSION="${BUILD_VERSION_NUMBER}" \
    .

## You know what all the cool kids like?  CI!  Time to test like a boss
# This is probably unsafe AND requires root.  I'd rather CI than no CI though, so for now it's happening
# This is unsafe in the following ways:
# The hwsim devices have to be 0-3, but if there are other wifi cards they won't be
# This just modprobes and rips out the module, needed or otherwise, which means it's not parallel safe at all

# Start by removing hwsim and then making 4 hwsim devices
CONTAINER_NAME="${CI_REGISTRY_IMAGE}-${IMAGE}-ci"
if lsmod | grep -q mac80211_hwsim; then
  sudo modprobe -r mac80211_hwsim
  sleep 5
fi
sudo modprobe mac80211_hwsim radios=8

# stop all running docker containers
if [ -n "$(docker ps -a -q)" ]; then
  docker stop $(docker ps -a -q)
fi
# remove any stopped containers which weren't removed already
if [ -n "$(docker ps -a -q)" ]; then
  docker rm $(docker ps -a -q)
fi

# Get a list of the radios (a little safer than assuming)
#CONTAINER_PHYS="$(sudo airmon-ng | awk '/mac80211_hwsim/ {print $1}')"
CONTAINER_PHYS="phy8 phy1 phy2 phy3 phy4 phy5 phy6 phy7"
CONTAINER_PHYS="$(sudo airmon-ng | awk '/mac80211_hwsim/ {print $1}')"
# Start the container
docker run -d --rm --network none --name "${CONTAINER_NAME}" \
  --tmpfs /run:mode=0755,nosuid,nodev,nr_inodes=800k,size=20%,strictatime \
  --tmpfs /tmp:mode=0755,nosuid,nodev,nr_inodes=800k,size=20% \
  $(if [ -d '/home/zero/development/rfhs/wctf-restricted' ]; then find '/home/zero/development/rfhs/wctf-restricted/wifi/openwrt/airkraken/files' -type f -exec printf "-v %s:%s\n" "{}" "{}" \; | sed 's#:/home/zero/development/rfhs/wctf-restricted/wifi/openwrt/airkraken/files#:#;s#$#:ro#'; fi) \
  --cap-add net_raw --cap-add net_admin \
  "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}"
  #--security-opt seccomp=unconfined \
# Give it radios
clientpid=$(docker inspect --format "{{ .State.Pid }}" "${CONTAINER_NAME}")
for phy in ${CONTAINER_PHYS}; do
  while true; do
    if iw phy "${phy}" info > /dev/null 2>&1; then
      unset driver
      driver="$(awk -F'=' '{print $2}' "/sys/class/ieee80211/${phy}/device/uevent")"
      if [ 'mac80211_hwsim' = "${driver}" ]; then
        printf "Found %s, moving it into %s\n" "${phy}" "${CONTAINER_NAME}"
        break
      else
        printf "Requested phy is using %s driver instead of the expected mac80211_hwsim.  Failing safe.\n" "${driver}"
        exit 1
      fi
    fi
    printf "Unable to find %s, waiting...\n" "${phy}"
    sleep 1
  done
  sudo iw phy "${phy}" set netns "${clientpid}"
done
sleep 20
if docker exec "${CONTAINER_NAME}" /usr/sbin/rfhs_checker; then
  docker stop "${CONTAINER_NAME}"
  sudo modprobe -r mac80211_hwsim
  #docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  #docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}"
  #docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  exit_code=0
else
  printf "rfhs_checker failed!\n"
  printf "%s/%s:%s is still running for your debugging pleasure\n" "${CI_REGISTRY_IMAGE}" "${IMAGE}" "${BUILD_VERSION_NUMBER}"
  exit_code=1
fi
rm "${TARBALL}"
exit "${exit_code}"
