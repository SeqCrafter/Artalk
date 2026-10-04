# syntax=docker/dockerfile:1

ARG ARTALK_GO_VERSION=1.26.5
ARG UPGIT_VERSION=v0.3.0

# ============================================================
# Stage 1: Build Artalk on Debian/glibc
# ============================================================
FROM golang:${ARTALK_GO_VERSION}-bookworm AS artalk-builder

WORKDIR /source

# Build tools + Node.js 22 + pnpm
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        make \
        git \
        curl \
        ca-certificates \
        gnupg; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    npm install -g pnpm@10.33.2; \
    rm -rf /var/lib/apt/lists/*

# Download Go dependencies separately to improve Docker layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy Artalk source
COPY . .

# Build frontend
ARG SKIP_UI_BUILD=false
RUN set -eux; \
    if [ "${SKIP_UI_BUILD}" = "false" ]; then \
        make build-frontend; \
    fi

# Build Artalk
ARG APP_VERSION=""
ARG APP_COMMIT_HASH=""

RUN set -eux; \
    if [ -n "${APP_VERSION}" ]; then export VERSION="${APP_VERSION}"; fi; \
    if [ -n "${APP_COMMIT_HASH}" ]; then export COMMIT_HASH="${APP_COMMIT_HASH}"; fi; \
    make build


# ============================================================
# Stage 2: Download Upgit
# ============================================================
FROM debian:bookworm-slim AS upgit-downloader

ARG TARGETARCH
ARG UPGIT_VERSION

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        unzip; \
    rm -rf /var/lib/apt/lists/*; \
    case "${TARGETARCH}" in \
        amd64) UPGIT_ARCH="amd64" ;; \
        arm64) UPGIT_ARCH="arm64" ;; \
        386)   UPGIT_ARCH="386" ;; \
        arm)   UPGIT_ARCH="arm" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -O /tmp/upgit.zip \
        "https://github.com/pluveto/upgit/releases/download/${UPGIT_VERSION}/upgit_linux_${UPGIT_ARCH}.zip"; \
    mkdir -p /tmp/upgit; \
    unzip /tmp/upgit.zip -d /tmp/upgit; \
    install -m 0755 /tmp/upgit/upgit /usr/local/bin/upgit


# ============================================================
# Stage 3: Final runtime image
# Debian/glibc runtime for both Artalk and Upgit
# ============================================================
FROM debian:bookworm-slim

ARG TZ="Asia/Shanghai"
ENV TZ="${TZ}"

# Runtime dependencies.
# libgcc-s1 / libstdc++6 provide the GCC runtime required by Upgit.
# libx11-6 is kept for compatibility with Upgit features that may use X11.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        tzdata \
        ca-certificates \
        libgcc-s1 \
        libstdc++6 \
        libx11-6; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

# Artalk executable built from source
COPY --from=artalk-builder /source/bin/artalk /artalk

# Upgit executable
COPY --from=upgit-downloader /usr/local/bin/upgit /usr/bin/upgit

# Preserve Artalk's official runner and entrypoint layout
COPY scripts/docker-artalk-runner.sh /usr/bin/artalk
RUN chmod +x /usr/bin/artalk \
    && ln -s /usr/bin/artalk /usr/bin/artalk-go

COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Fail the image build immediately if Upgit cannot start in this glibc image
RUN /usr/bin/upgit --version

VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 23366

CMD ["server", "--host", "0.0.0.0", "--port", "23366"]
