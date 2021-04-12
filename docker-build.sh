#!/bin/sh

set -e

DISTRO=openwrt
TARBALL="rfhs-rfctf-4.1.0-2021.04.12-public-openwrt-image-x86-64-generic-rootfs.tar.gz"
cp ~/development/openwrt/bin/targets/x86/64/"${TARBALL}" .

CI_REGISTRY_IMAGE=rfhs
BUILD_DATE=$(date -u +"%Y.%m.%d")
BUILD_VERSION=4.1.0

IMAGE=$DISTRO
VERSION=$BUILD_VERSION

docker build --pull -t "${CI_REGISTRY_IMAGE}/${IMAGE}:${VERSION}" \
    --build-arg TARBALL=${TARBALL} \
    --build-arg BUILD_DATE=${BUILD_DATE} \
    --build-arg VERSION=${VERSION} \
    .

docker tag "${CI_REGISTRY_IMAGE}/${IMAGE}:${VERSION}" "${CI_REGISTRY_IMAGE}/${IMAGE}:latest"
docker push "${CI_REGISTRY_IMAGE}/${IMAGE}:${VERSION}"
rm "${TARBALL}"
