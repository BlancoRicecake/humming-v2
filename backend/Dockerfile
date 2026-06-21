# syntax=docker/dockerfile:1.6
#
# Humming V2 — API server image
# Base: python:3.11-slim (Debian bookworm)
# Native deps:
#   - ffmpeg       → Opus / m4a / webm decoding (mobile uploads recorded as Opus)
#   - libsndfile1  → soundfile / librosa read+write of WAV/FLAC
#   - libgomp1     → OpenMP runtime for librosa/numpy
# Refs: docs/opus-integration-plan.md, docs/infra-mvp.html (section 1, 5)

FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    NUMBA_CACHE_DIR=/tmp/numba_cache \
    MPLCONFIGDIR=/tmp/mpl

# --- system deps -----------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ffmpeg \
        libsndfile1 \
        libgomp1 \
        libstdc++6 \
        ca-certificates \
        curl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- python deps (cached layer) -------------------------------------------
# build-essential (g++/gcc/make) is needed to compile C/C++ extensions that
# ship sdist-only — notably pyworld (WORLD vocoder, used by app/autotune.py).
# Installed only for this layer and purged after the wheels are built so the
# runtime image stays lean. libstdc++6 (linked by pyworld at runtime) is kept
# via the explicit install in the system-deps layer above.
COPY requirements.txt ./
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && pip install --upgrade pip \
 && pip install -r requirements.txt \
 && pip install "gunicorn>=21.2" \
 && apt-get purge -y --auto-remove build-essential \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# --- downloadable catalog soundfonts --------------------------------------
# Large CC0 .sf2 the backend renders with (guitar_lab / audition FluidSynth)
# AND the app downloads on demand via /soundfonts. gitignored (>100MB each, too
# big for GitHub) but present locally, so the Docker build context bakes them
# in. Kept as its own layer BEFORE the app source so app-only deploys reuse the
# cached ~1GB layer instead of rebuilding it.
COPY soundfonts ./soundfonts

# --- app source ------------------------------------------------------------
COPY app ./app
COPY migrations ./migrations
# bin/ kept optional (FluidSynth portable build); ignore in prod if absent
COPY bin ./bin

# --- build-time metadata --------------------------------------------------
# GIT_SHA injected by `flyctl deploy --build-arg GIT_SHA=$(git rev-parse --short HEAD)`
ARG GIT_SHA=local
ENV GIT_SHA=${GIT_SHA}

# --- runtime user ----------------------------------------------------------
RUN useradd --create-home --uid 1000 humming \
 && chown -R humming:humming /app
USER humming

EXPOSE 8080

# Healthcheck (Docker-level; Fly health checks live in fly.toml)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

# workers=1 → shared-cpu-1x@1GB. 두 워커가 numpy/librosa import + ffmpeg subprocess
# 를 동시에 메모리에 잡으면 1GB 한계로 OOM. 동시성은 머신 2대로 확보.
# numpy/openmp 스레드도 1로 고정(같은 이유 — 스레드별 BLAS 워크스페이스 메모리).
ENV OMP_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    NUMEXPR_NUM_THREADS=1
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--workers", "1", \
     "--timeout-keep-alive", "30", \
     "--proxy-headers", \
     "--forwarded-allow-ips", "*"]
