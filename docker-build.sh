#!/bin/sh

set -eux

rfkill_check() {
	#take phy and check blocks
	if [ -z "${1}" ]; then
		printf "Fatal, rfkill_check requires a phy to be passed in\n"
		exit 1
	fi
	#first we have to find the rfkill index
	#this is available as /sys/class/net/wlan0/phy80211/rfkill## but that's a bit difficult to parse
	index="$(sudo rfkill list | grep "${1}:" | head -n1 | awk -F: '{print $1}')"
	if [ -z "$index" ]; then
		return 187
	fi
	rfkill_status="$(sudo rfkill list "${index}" 2>&1)"
	if [ $? != 0 ]; then
		printf "rfkill error: %s\n" "${rfkill_status}"
		return 187
	elif [ -z "${rfkill_status}" ]; then
		printf "rfkill had no output, something went wrong.\n"
		exit 1
	else
		soft=$(printf "%s" "${rfkill_status}" | grep -i soft | awk '{print $3}')
		hard=$(printf "%s" "${rfkill_status}" | grep -i hard | awk '{print $3}')
		if [ "${soft}" = "yes" ] && [ "${hard}" = "no" ]; then
			return 1
		elif [ "${soft}" = "no" ] && [ "${hard}" = "yes" ]; then
			return 2
		elif [ "${soft}" = "yes" ] && [ "${hard}" = "yes" ]; then
			return 3
		fi
	fi
	return 0
}

rfkill_unblock() {
	#attempt unblock and CHECK SUCCESS
	#rfkill_status="$(sudo rfkill unblock "${1#phy}" 2>&1)"
	#if [ $? != 0 ]; then
		rfkill_status="$(sudo rfkill unblock "${index}" 2>&1)"
		if [ $? != 0 ]; then
      if [ "$(printf "%s" "${rfkill_status}" | grep -c "Usage")" -eq 1 ]; then
				printf "Missing parameters in rfkill! Report this"
			else
				printf "rfkill error: %s\n" "${rfkill_status}"
			fi
			printf "Unable to unblock.\n"
			return 1
		fi
	#fi

	sleep 1
	return 0
}

create_ns_link() {
  PID="$(docker inspect -f '{{.State.Pid}}' "${CONTAINER_NAME}")"
  if [ -z "${PID}" ]; then
    printf "Unable to identify process id for %s, skipping.\n" "${CONTAINER_NAME}"
    exit 1
  fi
  sudo mkdir -p /run/netns/
  if mountpoint -q -- "/run/netns/${CONTAINER_NAME}"; then
    # Remove the stale namespace mounting
	  printf "Stale namespace found at /run/netns/%s\n" "${CONTAINER_NAME}"
    printf "Removing stale namespace\n"
    sudo ip netns delete "${CONTAINER_NAME}"
  fi
  sudo touch "/run/netns/${CONTAINER_NAME}"
  printf "Mapping namespaces of process id %s for %s to namespace name %s\n" "${PID}" "${CONTAINER_NAME}" "${CONTAINER_NAME}"
  sudo mount -o bind "/proc/${PID}/ns/net" "/run/netns/${CONTAINER_NAME}"
}

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

docker build --no-cache -t \
  "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}" \
  --build-arg TARBALL="${TARBALL}" \
  --build-arg BUILD_DATE="${BUILD_DATE}" \
  --build-arg VERSION="${BUILD_VERSION_NUMBER}" \
  .

## You know what all the cool kids like?  CI!  Time to test like a boss
# This is probably unsafe AND requires root.  I'd rather CI than no CI though, so for now it's happening
# This is unsafe in the following ways:
# This just modprobes and rips out the module, needed or otherwise, which means it's not parallel safe at all

# Start by removing hwsim and then making 4 hwsim devices
CONTAINER_NAME="${CI_REGISTRY_IMAGE}-${IMAGE}-ci"
if lsmod | grep -q mac80211_hwsim; then
  sudo modprobe -r mac80211_hwsim
  sleep 5
fi
sudo modprobe mac80211_hwsim radios=8

if [ -n "$(docker ps --filter name="${CONTAINER_NAME}" --format '{{ .ID }}' )" ]; then
  echo "Found existing ${CONTAINER_NAME} container... QUITTING"
  exit 1
fi

# Get a list of the radios (a little safer than assuming)
CONTAINER_PHYS="$(sudo airmon-ng | awk '/mac80211_hwsim/ {print $1}')"
# Start the container
docker run -d --rm --network none --name "${CONTAINER_NAME}" \
  --tmpfs /run:mode=0755,nosuid,nodev,nr_inodes=800k,size=20%,strictatime \
  --tmpfs /tmp:mode=0755,nosuid,nodev,nr_inodes=800k,size=20% \
  --cap-add net_raw --cap-add net_admin \
  "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}"
  #$(if [ -d '/home/zero/development/rfhs/wctf-restricted' ]; then find '/home/zero/development/rfhs/wctf-restricted/wifi/openwrt/airkraken/files' -type f -exec printf "-v %s:%s\n" "{}" "{}" \; | sed 's#:/home/zero/development/rfhs/wctf-restricted/wifi/openwrt/airkraken/files#:#;s#$#:ro#'; fi) \
  #--security-opt seccomp=unconfined \
# Give it radios
create_ns_link
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
  rfkill_check "${phy}" || rfkill_unblock "${phy}"
  sudo iw phy "${phy}" set netns name "${CONTAINER_NAME}"
done
printf 'Sleeping for 30 seconds so openwrt can boot\n'
sleep 30
if docker exec "${CONTAINER_NAME}" /usr/sbin/rfhs_checker excessive; then
  docker stop "${CONTAINER_NAME}"
  sudo modprobe -r mac80211_hwsim
  docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}"
  docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
  exit_code=0
else
  printf "rfhs_checker failed!\n"
  printf "%s/%s:%s is still running for your debugging pleasure\n" "${CI_REGISTRY_IMAGE}" "${IMAGE}" "${BUILD_VERSION_NUMBER}"
  exit_code=1
fi
rm "${TARBALL}"
exit "${exit_code}"
