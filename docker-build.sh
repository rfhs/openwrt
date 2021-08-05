#!/bin/sh

set -e

DISTRO=openwrt
BUILD_VERSION=4.2.1
TARBALL="rfhs-rfctf-${BUILD_VERSION}-2021.08.04-public-openwrt-image-x86-64-generic-rootfs.tar.gz"
cp ~/development/openwrt/bin/targets/x86/64/"${TARBALL}" .

CI_REGISTRY_IMAGE=rfhs
BUILD_DATE=$(date -u +"%Y.%m.%d")

IMAGE=$DISTRO
VERSION=$BUILD_VERSION

docker build --pull -t "${CI_REGISTRY_IMAGE}/${IMAGE}:${VERSION}" \
    --build-arg TARBALL=${TARBALL} \
    --build-arg BUILD_DATE=${BUILD_DATE} \
    --build-arg VERSION=${VERSION} \
    .

docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${VERSION}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${VERSION}"
docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
rm "${TARBALL}"
