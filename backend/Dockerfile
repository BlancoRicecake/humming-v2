# syntax=docker/dockerfile:1.6
#
# Humming V2 — API server image
# Base: python:3.11-slim (currently Debian trixie; verify the resolved image)
# Native deps:
#   - ffmpeg       → Opus / m4a / webm decoding (mobile uploads recorded as Opus)
#   - libsndfile1  → soundfile / librosa read+write of WAV/FLAC
#   - libgomp1     → OpenMP runtime for librosa/numpy
# Refs: docs/opus-integration-plan.md, docs/infra-mvp.html (section 1, 5)

ARG PYTHON_IMAGE=python:3.11-slim@sha256:673719e071ecf27434fd2635bbd8d00f49f4fdd81f243143438a42ced8bedf60
FROM ${PYTHON_IMAGE} AS shell-build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential autoconf automake curl ca-certificates patch \
 && rm -rf /var/lib/apt/lists/*
COPY runtime/build_shell.sh /src/runtime/build_shell.sh
RUN sh /src/runtime/build_shell.sh

FROM ${PYTHON_IMAGE} AS sqlite-build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential curl ca-certificates tcl \
 && rm -rf /var/lib/apt/lists/*
COPY runtime/build_sqlite.sh /src/runtime/build_sqlite.sh
RUN sh /src/runtime/build_sqlite.sh

FROM ${PYTHON_IMAGE} AS zlib-build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential curl ca-certificates patch \
 && rm -rf /var/lib/apt/lists/*
COPY runtime/build_zlib.sh runtime/zlib-negative-length.patch /src/runtime/
RUN sh /src/runtime/build_zlib.sh

FROM ${PYTHON_IMAGE} AS native-build

# Native security fixes are built from verified upstream sources; Debian stable
# still ships affected FFmpeg/libsndfile. Keep compilers and source build tools
# out of the runtime stage. Build scripts, hashes, patches and licenses live in
# native/; the exact corresponding source is retained inside the final image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential cmake pkg-config nasm curl ca-certificates gnupg patch xz-utils \
    libflac-dev libogg-dev libvorbis-dev libopus-dev \
 && rm -rf /var/lib/apt/lists/*
COPY native /src/native
RUN sh /src/native/build.sh

FROM ${PYTHON_IMAGE} AS app-build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    NUMBA_CACHE_DIR=/tmp/numba_cache \
    MPLCONFIGDIR=/tmp/mpl

# --- system deps -----------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libflac14 libogg0 libvorbis0a libvorbisenc2 libopus0 \
        libgomp1 \
        libstdc++6 \
        ca-certificates \
        curl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY --from=native-build /opt/native/ /usr/local/
COPY --from=sqlite-build /opt/sqlite/ /usr/local/
COPY --from=zlib-build /opt/zlib/ /usr/local/
COPY --from=shell-build /opt/shell/ /usr/local/
RUN ln -s dash /usr/local/bin/sh
RUN ldconfig

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
 && pip install --no-binary=soundfile -r requirements.txt \
 && apt-get purge -y --auto-remove build-essential \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY runtime /src/runtime
RUN python /src/runtime/patch_pyworld.py \
 && python -m pip uninstall -y pip wheel setuptools
RUN python /usr/local/share/humtrack-native/verify_runtime.py

# --- downloadable catalog soundfonts --------------------------------------
# Large CC0 .sf2 the backend renders with (guitar_lab / audition FluidSynth)
# AND the app downloads on demand via /soundfonts. gitignored (>100MB each, too
# big for GitHub) but present locally, so the Docker build context bakes them
# in. Kept as its own layer BEFORE the app source so app-only deploys reuse the
# cached ~1GB layer instead of rebuilding it.
COPY soundfonts ./soundfonts
COPY verify_soundfonts.py ./verify_soundfonts.py
# A Git checkout can contain catalog.json but none of the ignored .sf2 files.
# Refuse that image rather than silently publishing an empty download list.
RUN python verify_soundfonts.py
# Pre-compute the catalog sha256 sidecar so a fresh machine never hashes 1GB
# on its first /soundfonts request (was ~50s, every morning after Fly stopped
# the idle machine). Standalone script on purpose: this layer must not depend
# on app/ or it would rebuild on every code change.
RUN python - <<'PY'
import hashlib, json, os
base = "soundfonts"
out = {}
for name in sorted(os.listdir(base)):
    if not name.endswith(".sf2"):
        continue
    p = os.path.join(base, name)
    st = os.stat(p)
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    out[f"{name}:{st.st_size}"] = h.hexdigest()  # no mtime: see app/soundfonts.py _key
with open(os.path.join(base, ".sha256.json"), "w") as f:
    json.dump(out, f, indent=0, sort_keys=True)
print(f"sha256 sidecar: {len(out)} soundfont(s)")
PY

# --- app source ------------------------------------------------------------
COPY app ./app
# Learned-correction weights (pitch/offset/drum classifier, ~3MB of .npz tracked
# in git). app/*_correction.py resolve them relative to app/ as ../models — without
# this COPY production silently ran the heuristic fallbacks (audit B9). The
# startup log in app/main.py reports whether each one loaded.
COPY models ./models
COPY migrations ./migrations
# bin/ kept optional (FluidSynth portable build); ignore in prod if absent
COPY bin ./bin

# Retain the compilation/installation scripts and regression sources with the
# corresponding LGPL source archives and patches, outside the app's endpoints.
COPY native /usr/local/share/humtrack-native/build-tools/
COPY runtime /usr/local/share/humtrack-runtime/build-tools/

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
USER root
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --only-upgrade tzdata \
 && rm -rf /var/lib/apt/lists/*
RUN python /src/runtime/assemble.py
RUN chroot /runtime-root /usr/local/bin/python -c "import sqlite3,ssl,numpy,scipy,pyworld,soundfile,importlib.util; assert sqlite3.sqlite_version == '3.54.1'; assert importlib.util.find_spec('setuptools') is None; print('Minimal runtime core imports and SQLite version verified')"

# Only selected runtime files and their truthful package provenance survive.
# No package manager or build tools; configured dash and ldconfig retain operator/ctypes
# compatibility. Existing image tags and public services are not changed.
FROM scratch AS runtime
COPY --from=app-build /runtime-root/ /
COPY --from=app-build --chown=1000:1000 /app/ /app/
WORKDIR /app
ARG GIT_SHA=local
ENV GIT_SHA=${GIT_SHA} \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    HOME=/home/humming LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE="" LOCALDOMAIN="" \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    NUMBA_CACHE_DIR=/tmp/numba_cache MPLCONFIGDIR=/tmp/mpl \
    OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1
USER 1000:1000
EXPOSE 8080
RUN ["python", "/usr/local/share/humtrack-runtime/build-tools/verify_runtime.py"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=4).status == 200"]
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--workers", "1", \
     "--timeout-keep-alive", "30", \
     "--proxy-headers", \
     "--forwarded-allow-ips", "*"]
