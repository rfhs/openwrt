FROM scratch

# Metadata params
ARG BUILD_DATE
ARG VERSION
ARG TARBALL

# https://github.com/opencontainers/image-spec/blob/master/annotations.md
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.vendor='RF Hackers Sanctuary' \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.title="RFHS Openwrt" \
      org.opencontainers.image.description="Official RFHS Openwrt docker image" \
      org.opencontainers.image.url='https://github.com/rfhs/openwrt' \
      org.opencontainers.image.authors="RFHS"

#here we pull in the rootfs from catalyst
ADD $TARBALL /

CMD ["/sbin/init"]
