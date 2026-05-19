# TASK-110 v1.1 (2026-05-20): whisper.cpp local STT для clip transcripts.
# Replaces OpenAI Whisper API per PO cost=$0 Day-0 directive.
#
# Build: docker build -t ghcr.io/himratesdev/himrate-whisper:small-v1 -f whisper/Dockerfile whisper/
# Push: docker push ghcr.io/himratesdev/himrate-whisper:small-v1
# Deploy: kamal accessory boot whisper -d staging (создаёт container)
# Reboot после rebuild: kamal accessory reboot whisper -d staging
#
# Image size: ~600MB (~100MB Alpine base + ~500MB small model file baked).
# CPU realtime: ~3-5× для small model на Time4VPS x86_64 (3 cores shared).
# Hard timeout: 600s в WhisperLocalClient (HARD_TIMEOUT_SEC) — Sidekiq job retry 3× если exceeded.

FROM debian:bookworm-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      git \
      ca-certificates \
      curl && \
    rm -rf /var/lib/apt/lists/*

# Pin whisper.cpp к specific version (reproducible builds).
# Update via dependabot / manual quarterly review (per CLAUDE.md ops cadence для whisper.cpp).
ARG WHISPER_CPP_VERSION=v1.7.6
RUN git clone --depth 1 --branch ${WHISPER_CPP_VERSION} https://github.com/ggerganov/whisper.cpp.git /src/whisper.cpp

WORKDIR /src/whisper.cpp
RUN cmake -B build -DGGML_OPENMP=ON && \
    cmake --build build -j --config Release

# Download small.en model (~466MB) baked в image для reproducibility.
# Alternative models: tiny (75MB) / base (142MB) / medium (1.5GB) — small chosen
# per ADR-110 §3.2 SA-2 (quality 70-85% vs ops/RAM cost trade-off).
RUN ./models/download-ggml-model.sh small

# Runtime image — minimal Debian с whisper.cpp binary + model.
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libgomp1 \
      ffmpeg \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/whisper.cpp/build/bin/whisper-cli /usr/local/bin/whisper
COPY --from=builder /src/whisper.cpp/models/ggml-small.bin /opt/whisper/models/ggml-small.bin

# Wrapper script: kamal accessory exec himrate-whisper -- whisper {audio_path}
# → loads model from /opt/whisper/models/ggml-small.bin automatically.
RUN printf '#!/bin/sh\nexec /usr/local/bin/whisper -m /opt/whisper/models/ggml-small.bin "$@"\n' > /usr/local/bin/whisper-wrap && \
    chmod +x /usr/local/bin/whisper-wrap && \
    ln -sf /usr/local/bin/whisper-wrap /usr/local/bin/whisper

# Tail entrypoint: keeps container alive для `kamal accessory exec` invocations.
# Whisper.cpp itself is invoked on-demand per job, не daemon.
CMD ["sh", "-c", "tail -f /dev/null"]
