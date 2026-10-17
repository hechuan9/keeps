FROM rust:1.94-bookworm AS build
WORKDIR /src
COPY server/Cargo.toml server/Cargo.lock ./
COPY server/src ./src
RUN cargo build --release --locked \
    && mkdir -p /xmp-licenses \
    && cp /usr/local/cargo/registry/src/*/xmp_toolkit-*/LICENSE-* /usr/local/cargo/registry/src/*/xmp_toolkit-*/NOTICE.txt /xmp-licenses/ \
    && cp /usr/local/cargo/registry/src/*/xmp_toolkit-*/external/xmp_toolkit/LICENSE /xmp-licenses/XMP-SDK-LICENSE \
    && cp /usr/local/cargo/registry/src/*/xmp_toolkit-*/external/libexpat/COPYING /xmp-licenses/EXPAT-COPYING \
    && cp /usr/local/cargo/git/checkouts/exif-rs-*/*/LICENSE /xmp-licenses/EXIF-RS-LICENSE

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tzdata python3 imagemagick libraw-bin libimage-exiftool-perl libheif-examples libheif-plugin-libde265 libheif-plugin-x265 libheif-plugin-jpegdec util-linux ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /xmp-licenses /usr/share/doc/keeps-xmp
COPY --from=build /src/target/release/keeps-server /usr/local/bin/keeps-server
COPY --from=build /src/target/release/keeps-inspect /usr/local/bin/keeps-inspect
COPY --from=build /src/target/release/keeps-render /usr/local/bin/keeps-render
COPY scripts/linux_cache_worker.py /usr/local/bin/linux_cache_worker.py
ENV RUST_LOG=keeps_server=info,tower_http=info RUST_BACKTRACE=1
EXPOSE 2283
ENTRYPOINT ["keeps-server"]
