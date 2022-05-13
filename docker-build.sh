#!/bin/sh

set -eux

TARBALL_FOLDER="${HOME}/development/openwrt/bin/targets/x86/64/"
DISTRO=openwrt
BUILD_VERSION_NUMBER="$(awk -F'"' '/CONFIG_VERSION_NUMBER/ {print $2}' "${TARBALL_FOLDER}/../../../../.config" )"
BUILD_VERSION_CODE="$(awk -F'"' '/CONFIG_VERSION_CODE=/ {gsub(" ", "-"); print tolower($2)}' "${TARBALL_FOLDER}/../../../../.config" )"
TARBALL="rfhs-rfctf-${BUILD_VERSION_NUMBER}-${BUILD_VERSION_CODE}-x86-64-generic-rootfs.tar.gz"
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
sudo modprobe mac80211_hwsim radios=4

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
CONTAINER_PHYS="phy0 phy1 phy2 phy3"
# Start the container
docker run -d --rm --network none --name "${CONTAINER_NAME}" \
  --cap-add net_raw --cap-add net_admin --cap-add=SYS_ADMIN \
  "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}"
  #--security-opt seccomp=unconfined \
# Give it radios
clientpid=$(docker inspect --format "{{ .State.Pid }}" "${CONTAINER_NAME}")
for phy in ${CONTAINER_PHYS}; do
  while true; do
    if iw phy "${phy}" info > /dev/null 2>&1; then
      printf "Found %s, moving it into %s\n" "${phy}" "${CONTAINER_NAME}"
      break
    fi
    printf "Unable to find %s, waiting...\n" "${phy}"
    sleep 1
  done
  sudo iw phy "${phy}" set netns "${clientpid}"
done
sleep 90
if docker exec "${CONTAINER_NAME}" /usr/sbin/rfhs_checker; then
  docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}"
  docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  exit_code=0
else
  printf "rfhs_checker failed!\n"
  exit_code=1
fi
docker stop "${CONTAINER_NAME}"
sudo modprobe -r mac80211_hwsim
rm "${TARBALL}"
exit "${exit_code}"
