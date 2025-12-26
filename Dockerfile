# ------------------------------------------------------------------------------
# Stage 1: Download FaceFusion source tarball
# ------------------------------------------------------------------------------
FROM docker.io/library/alpine:3.23 AS facefusion-tarball
ARG FACEFUSION_VERSION=latest
RUN apk add --no-cache jq ca-certificates curl
WORKDIR /out

RUN <<'EOF'
set -eux -o pipefail
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY NO_PROXY no_proxy || true

version="${FACEFUSION_VERSION:-latest}"

if [ "${version}" = "latest" ]; then
  version="$(curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/facefusion/facefusion/releases/latest" \
    | jq -r '.tag_name')"
fi

echo "${version}" > version.txt
echo "Downloading FaceFusion ${version}"

url="https://github.com/facefusion/facefusion/archive/refs/tags/${version}.tar.gz"
curl -fL --compressed \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --retry 10 --retry-all-errors --retry-delay 1 \
  --connect-timeout 10 --speed-time 30 --speed-limit 10240 \
  -C - \
  -o facefusion.tar.gz.part \
  "${url}"
mv facefusion.tar.gz.part facefusion.tar.gz
EOF

# ------------------------------------------------------------------------------
# Stage 2b: Extract and patch FaceFusion source
# ------------------------------------------------------------------------------
FROM docker.io/library/python:3.12-alpine AS facefusion-source

WORKDIR /facefusion-src
COPY scripts/vast/patch-facefusion.py /tmp/patch-facefusion.py
COPY --from=facefusion-tarball /out/facefusion.tar.gz /tmp/facefusion.tar.gz
COPY --from=facefusion-tarball /out/version.txt /tmp/version.txt

RUN set -eux; \
    version="$(cat /tmp/version.txt)"; \
    echo "Using FaceFusion ${version}"; \
    tar -xzf /tmp/facefusion.tar.gz --strip-components=1 -C /facefusion-src; \
    python /tmp/patch-facefusion.py /facefusion-src

# ------------------------------------------------------------------------------
# Stage 3: Download Python dependencies (TRIXIE slim + uv binary)
# ------------------------------------------------------------------------------
FROM docker.io/library/python:3.12-slim-trixie AS python-builder

ENV UV_CACHE_DIR=/root/.cache/uv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /build

RUN --mount=type=cache,target=/root/.cache/uv uv pip install --target=/packages \
    tensorrt==10.12.0.36 --extra-index-url https://pypi.nvidia.com

COPY --from=facefusion-source /facefusion-src/ .
RUN test -f requirements.txt

RUN --mount=type=cache,target=/root/.cache/uv grep -v "^onnxruntime" requirements.txt > /tmp/requirements.txt \
    && uv pip install --target=/packages -r /tmp/requirements.txt

RUN --mount=type=cache,target=/root/.cache/uv uv pip install --target=/packages onnxruntime-gpu

# ------------------------------------------------------------------------------
# Stage 4: Final runtime image
# ------------------------------------------------------------------------------
FROM docker.io/nvidia/cuda:12.9.1-cudnn-runtime-ubuntu24.04

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

LABEL org.opencontainers.image.title="FaceFusion Unleashed" \
    org.opencontainers.image.description="Minimal FaceFusion build tailored for Vast.ai, NSFW checks removed and CUDA runtime trimmed for fast starts" \
    org.opencontainers.image.version="${VERSION:-latest}" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.revision="${VCS_REF}" \
    org.opencontainers.image.source="https://github.com/facefusion/facefusion" \
    org.opencontainers.image.url="https://github.com/mlshdev/ff-unleashed-vast" \
    org.opencontainers.image.documentation="https://docs.facefusion.io" \
    org.opencontainers.image.authors="FaceFusion Contributors & mlshdev" \
    org.opencontainers.image.vendor="FaceFusion" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.ref.name="${VERSION:-latest}" \
    org.opencontainers.image.base.name="nvidia/cuda:12.9.1-cudnn-runtime-ubuntu24.04"

# Optional: Copy NVIDIA libraries if needed for GPU acceleration
# These are provided by the CUDA runtime image, but we ensure they're accessible
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    WORKSPACE=/workspace \
    OPEN_BUTTON_PORT=7860 \
    GRADIO_SERVER_NAME=0.0.0.0 \
    GRADIO_SERVER_PORT=7860 \
    PYTHONPATH=/packages:/opt/facefusion \
    PATH=/opt/ffmpeg/bin:${PATH} \
    LD_LIBRARY_PATH=/packages/tensorrt_libs:/opt/ffmpeg/lib:/usr/local/cuda/targets/x86_64-linux/lib:/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH} \

    RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    openssh-server \
    supervisor \
    libgl1 \
    libglib2.0-0 \
    ca-certificates \
    libgomp1 \
    libxcb1 \
    libxcb-shm0 \
    libxcb-xfixes0 \
    libx11-6 \
    libxext6 \
    libxrender1 \
    && apt-get install ffmpeg git-all -y \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config \
    && sed -i "s/#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config

COPY --from=python-builder /packages /packages
COPY --from=python-builder /build /opt/facefusion
COPY config/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/supervisor/conf.d/ /etc/supervisor/conf.d/
COPY scripts/vast/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/log/supervisor

EXPOSE 22 7860
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
