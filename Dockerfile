# Build stage -----------------------------------------------------------------
FROM swift:6.3-noble AS build

WORKDIR /build

# Manifests first, on their own layer. Dependency resolution and the compilation of
# Hummingbird/PostgresNIO is the slow part of this build; keeping it above the source
# copy means editing a .swift file doesn't re-resolve or rebuild any of it.
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Tests aren't built here, but the manifest declares the target — without its directory
# present SwiftPM infers the sources and collides with the real targets.
COPY Tests ./Tests
COPY Sources ./Sources

# --static-swift-stdlib links the Swift runtime into the binary, so the final image
# needs no Swift toolchain: a 346 MB image (145 MB binary on a plain Ubuntu base)
# rather than shipping the 5.3 GB build image.
RUN swift build -c release --product stele --static-swift-stdlib \
    && mkdir -p /staging \
    && cp "$(swift build -c release --show-bin-path)/stele" /staging/stele

# Runtime stage ---------------------------------------------------------------
FROM ubuntu:24.04 AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged. Nothing here writes to disk — pages go to Postgres — so the binary is
# all this user needs, and it owns none of it.
RUN groupadd --system stele && useradd --system --gid stele --no-create-home stele

COPY --from=build /staging/stele /usr/local/bin/stele

USER stele
EXPOSE 8080

# Must bind all interfaces: the loopback default would only be reachable from inside
# the container, so the published port would connect to nothing.
ENV STELE_HOST=0.0.0.0 \
    STELE_PORT=8080

# Lets `depends_on: condition: service_healthy` work for anything placed in front of
# this, and gives the container runtime something to restart on.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/stele"]
