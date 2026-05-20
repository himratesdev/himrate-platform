# TASK-110 v1.3 (2026-05-20): whisper.cpp HTTP server для clip transcripts (tag small-v3).
# Replaces OpenAI Whisper API per PO cost=$0 Day-0 directive (ADR-110 v1.1 SA-2 swap A→B).
#
# v1.3 (BUG-110-A fix): runtime stage копирует libwhisper.so.1 + libggml*.so + libggml-cpu.so
#   из builder + ldconfig. v1.2 их пропускал → ld-linux exit 127 crash-loop (DV caught).
# v1.2 (Backend CR iter-1 M-2/M-3 fix): runs whisper.cpp NATIVE HTTP SERVER (whisper-server)
# instead of `kamal accessory exec` (which is architecturally broken — kamal = deploy CLI,
# не работает изнутри Rails container). Rails ClipTranscriptWorker → HTTP multipart POST
# к http://himrate-whisper:8080/inference (Docker network), audio передаётся multipart
# (no shared volume needed — M-3 fix).
#
# Build/push: CI workflow .github/workflows/build-whisper-image.yml (mirrors build-db-image.yml).
#   Pre-merge: `gh workflow run build-whisper-image.yml --ref <feature-branch>` (workflow_dispatch)
#     → builds + pushes ghcr.io/himratesdev/himrate-whisper:<tag> ПЕРЕД merge.
#   Post-merge: auto-rebuild on push к main с изменением whisper/Dockerfile OR deploy.yml tag.
#   Tag = SINGLE SOURCE из config/deploy.yml accessories.whisper.image (zero drift).
# Deploy: kamal accessory boot whisper -d staging (initial — accessory ранее не существовал).
# Reboot после rebuild: kamal accessory reboot whisper -d staging.
#
# Image size: ~600MB (~100MB Debian slim + ~500MB small model file baked).
# CPU realtime: ~3-5× для small model на Time4VPS x86_64 (--cpus="1.5" cap в deploy.yml).
# Concurrency=1 enforced via dedicated whisper_worker Sidekiq role (deploy.yml), не здесь.

FROM debian:bookworm-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      git \
      ca-certificates \
      curl && \
    rm -rf /var/lib/apt/lists/*

# NB: curl REQUIRED — models/download-ggml-model.sh нуждается в wget OR curl для
# download ggml-small.bin (без него: "Either wget or curl is required" → build fail).

# Pin whisper.cpp к specific version (reproducible builds).
# Update via dependabot / manual quarterly review (per CLAUDE.md ops cadence для whisper.cpp).
ARG WHISPER_CPP_VERSION=v1.7.6
RUN git clone --depth 1 --branch ${WHISPER_CPP_VERSION} https://github.com/ggerganov/whisper.cpp.git /src/whisper.cpp

WORKDIR /src/whisper.cpp
# Build whisper-server (HTTP server example) + whisper-cli.
RUN cmake -B build -DGGML_OPENMP=ON -DWHISPER_BUILD_SERVER=ON && \
    cmake --build build -j --config Release

# Download small model (~466MB) baked в image для reproducibility.
# Alternative models: tiny (75MB) / base (142MB) / medium (1.5GB) — small chosen
# per ADR-110 §3.2 SA-2 (quality 70-85% vs ops/RAM cost trade-off).
RUN ./models/download-ggml-model.sh small

# Runtime image — minimal Debian с whisper-server binary + model.
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libgomp1 \
      ca-certificates \
      curl && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/whisper.cpp/build/bin/whisper-server /usr/local/bin/whisper-server
COPY --from=builder /src/whisper.cpp/models/ggml-small.bin /opt/whisper/models/ggml-small.bin

# BUG-110-A: whisper-server динамически линкуется с libwhisper.so.1 + libggml*.so
# (BUILD_SHARED_LIBS=ON default). Multi-stage runtime ДОЛЖЕН копировать .so из builder,
# иначе ld-linux не разрешит зависимости → exit 127 crash-loop. ldconfig обновляет cache.
COPY --from=builder /src/whisper.cpp/build/src/libwhisper.so* /usr/local/lib/
COPY --from=builder /src/whisper.cpp/build/ggml/src/libggml*.so /usr/local/lib/
COPY --from=builder /src/whisper.cpp/build/ggml/src/ggml-cpu/libggml-cpu.so /usr/local/lib/
RUN ldconfig

# N-5 (CR): non-root user — security hardening (Rails compromise не эскалирует в whisper).
RUN useradd --system --uid 1000 --no-create-home whisper && \
    chown -R whisper:whisper /opt/whisper
USER whisper

EXPOSE 8080

# N-9 (CR): HEALTHCHECK — whisper-server /health endpoint (Kamal healthcheck + DV verify).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:8080/health || exit 1

# whisper-server HTTP daemon: POST /inference multipart (file=@audio.wav) → JSON {text, segments}.
# --convert enables ffmpeg-less WAV ingest; clients send 16kHz mono WAV (Rails ffmpeg pre-converts).
CMD ["whisper-server", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--model", "/opt/whisper/models/ggml-small.bin", \
     "--inference-path", "/inference", \
     "--threads", "2"]
