FROM falcon-test-builder:ubuntu24.04

# Proxy injected at build time via --build-arg.
ARG HTTP_PROXY=
ARG HTTPS_PROXY=
ENV http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    no_proxy=localhost,127.0.0.1,host.docker.internal,192.168.215.0/24,0.250.250.0/24 \
    NO_PROXY=localhost,127.0.0.1,host.docker.internal,192.168.215.0/24,0.250.250.0/24 \
    DEBIAN_FRONTEND=noninteractive

# Apt proxy config (no DNS needed, all routed through mihomo).
RUN if [ -n "$HTTP_PROXY" ]; then \
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' \
        "$HTTP_PROXY" "$HTTPS_PROXY" > /etc/apt/apt.conf.d/00proxy; fi

# Minimal SPDK build deps for nvmf + tcp + malloc bdev (no compress, no nvme-pci).
# Retry to ride out flaky upstream proxy.
RUN apt-get update && \
    for i in 1 2 3; do \
        apt-get install -y --fix-missing --no-install-recommends \
            gcc g++ make pkg-config \
            libcunit1-dev libaio-dev libssl-dev libjson-c-dev uuid-dev libnuma-dev \
            meson ninja-build \
            python3 python3-pip python3-dev python3-pyelftools python3-yaml \
            git ca-certificates \
            iproute2 iputils-ping nvme-cli fio \
        && break || sleep 5; \
    done && \
    rm -rf /var/lib/apt/lists/*

# pip deps (DPDK build script imports a few).
RUN if [ -n "$HTTPS_PROXY" ]; then \
        pip3 install --break-system-packages --proxy "$HTTPS_PROXY" \
            ninja meson pyelftools; \
    fi

# Strip proxy from final image — runtime should not depend on it.
ENV http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY=
RUN rm -f /etc/apt/apt.conf.d/00proxy

WORKDIR /spdk
