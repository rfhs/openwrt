#!/bin/sh

set -e

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

docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${BUILD_VERSION_NUMBER}"
docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
rm "${TARBALL}"
