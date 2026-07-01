# syntax=docker/dockerfile:1
# ----------------------------------------------------------------
# Builder
# ----------------------------------------------------------------
FROM alpine:latest AS builder

ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
ARG VERSION=0.0.0-docker

RUN apk add --no-cache \
    curl \
    xz \
    tar \
    ca-certificates \
    build-base \
    linux-headers \
    git \
    pkgconf

# download and install the compiler based on the TARGETARCH
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) ZIG_ARCH="x86_64" ;; \
      arm64) ZIG_ARCH="aarch64" ;; \
      *) echo "Unsupported arch: $TARGETARCH"; exit 1 ;; \
    esac; \
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt; \
    tar -xf /tmp/zig.tar.xz -C /opt; \
    mv /opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION} /opt/zig; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

WORKDIR /app

COPY . .

RUN zig build -Doptimize=ReleaseSmall -Dversion=${VERSION}


# ----------------------------------------------------------------
# Runner
# ----------------------------------------------------------------
FROM alpine:latest AS runner

WORKDIR /app

RUN apk add --no-cache ca-certificates

COPY --from=builder /app/zig-out/bin/evilblog /app/evilblog
COPY --from=builder /app/evilblog.zon /app/evilblog.zon
COPY --from=builder /app/statics /app/statics

CMD ["/app/evilblog"]
