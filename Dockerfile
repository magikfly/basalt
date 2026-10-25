# syntax=docker/dockerfile:1
# Container image for Basalt, the local inference engine for Qwen3.8-Flash-Next.
#
# Multi-stage: the engine is compiled in the CUDA devel image, the runtime image
# carries only the CUDA runtime libraries plus the Python server.
#
# Built by .github/workflows/basalt-image.yml and published to
# ghcr.io/magikfly/basalt. This file is a fork-local addition; upstream
# jesdga95/basalt ships no container definition.
#
# Three upstream facts this file depends on:
#   - src/program/generate.cpp hardcodes BASALT_SOURCE_DIR (the CMake source
#     directory, resolved at COMPILE time) and `basalt serve` chdirs into it to
#     launch the Python server. The build stage therefore compiles in /opt/basalt,
#     the exact path the runtime image serves from - a mismatch is a hard
#     `cannot enter the source tree` failure at startup.
#   - CMakeLists.txt sets RUNTIME_OUTPUT_DIRECTORY to ${CMAKE_SOURCE_DIR}/bin for
#     basalt, basalt-bench and basalt-probe, so binaries land in the SOURCE tree's
#     bin/, not build/bin/. basalt-vision comes from add_subdirectory(tools/vision).
#   - serve/engine/modelfile.py looks for basalt-vision as a sibling of the engine
#     binary, so all four have to share one directory.
#
# There is no GPU on a build runner, so nothing here executes the engine. The
# checks below verify what this file can actually get wrong: every shipped binary
# existing, the runtime image resolving every library the engine links, and the
# Python server importing from the copied tree.

ARG CUDA_DEVEL=nvidia/cuda:13.2.1-devel-ubuntu24.04
ARG CUDA_RUNTIME=nvidia/cuda:13.2.1-runtime-ubuntu24.04

# ---------------------------------------------------------------- build stage
FROM ${CUDA_DEVEL} AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      ninja-build \
      git \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/basalt
COPY . .

# --------------------------------------------------------------- build stamp
# BASALT_VERSION comes from CMakeLists.txt's project() version. The engine prints
# it in its INFO line and serve/engine/process.py hands that to the web UI as
# Hardware > Engine > Build. Upstream keeps it at 0.0.1, so every night's image
# claims to be the same build; CI passes the upstream commit this tree was merged
# from and it is compiled in as 0.0.1+8d73a394 - the same 12 hex characters as the
# immutable upstream-<sha12> tag, so the number on screen names the code running.
#
# Rewritten in the build context only; nothing here is pushed to GitHub. If
# upstream reformats that line the stamp is dropped with a warning rather than
# failing the image build - a display string must not block the engine update
# riding with it. The strings check further down covers the other direction: a
# stamp that was asked for and did not reach the binary fails the build.
ARG BASALT_BUILD_ID=""
RUN set -eu; \
    if [ -z "${BASALT_BUILD_ID}" ]; then \
      echo "no BASALT_BUILD_ID - version left as upstream defines it"; \
      : > /tmp/build_id; \
    elif cp CMakeLists.txt /tmp/CMakeLists.orig && \
      sed 's/BASALT_VERSION="${PROJECT_VERSION}"/BASALT_VERSION="'"${BASALT_BUILD_ID}"'"/' \
        /tmp/CMakeLists.orig > CMakeLists.txt && \
      ! cmp -s /tmp/CMakeLists.orig CMakeLists.txt; then \
      echo "stamped BASALT_VERSION=${BASALT_BUILD_ID}"; \
      printf '%s' "${BASALT_BUILD_ID}" > /tmp/build_id; \
    else \
      cp /tmp/CMakeLists.orig CMakeLists.txt; \
      echo "WARNING: BASALT_VERSION line not in the expected shape; using the upstream version"; \
      : > /tmp/build_id; \
    fi

# arch 120 (Blackwell) is the only architecture Basalt builds for; CMakeLists.txt
# hard-fails on anything else. Compiling needs no GPU.
RUN cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      -DCMAKE_CUDA_ARCHITECTURES=120 \
    && cmake --build build -j"$(nproc)"

# Collect the shipped binaries. Located by name rather than by a hardcoded build
# path so a change to RUNTIME_OUTPUT_DIRECTORY upstream fails this step loudly
# instead of quietly producing an image missing its encoder.
RUN set -eux; \
    mkdir -p /artifacts/bin; \
    for b in basalt basalt-bench basalt-probe basalt-vision; do \
      src="$(find /opt/basalt -type f -name "$b" -perm -u+x -printf '%s\t%p\n' | sort -rn | head -1 | cut -f2-)"; \
      test -n "$src" || { echo "MISSING: $b was not produced by the build"; exit 1; }; \
      cp -a "$src" /artifacts/bin/; \
    done; \
    ls -l /artifacts/bin

# Proof the stamp survived compilation. Without it the Build field would report
# a commit that the binary is not built from, which is worse than 0.0.1.
RUN set -eu; \
    id="$(cat /tmp/build_id)"; \
    if [ -z "$id" ]; then echo "no build id to verify"; exit 0; fi; \
    if ! command -v strings >/dev/null 2>&1; then \
      echo "WARNING: no strings(1) on the builder; the build id is unverified"; exit 0; \
    fi; \
    strings /artifacts/bin/basalt | grep -qF "$id" \
      || { echo "BUILD ID $id did not reach the engine binary"; exit 1; }; \
    echo "verified: bin/basalt reports version $id"

# ------------------------------------------------------------- runtime stage
FROM ${CUDA_RUNTIME} AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      python3-venv \
      python3-pip \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/basalt

# The venv lives at /opt/basalt/.venv on purpose: src/platform/system.cpp looks
# for <src_dir>/.venv/bin/python, so `basalt serve` finds the interpreter with no
# --python flag at all.
COPY requirements.txt ./
RUN python3 -m venv /opt/basalt/.venv \
    && /opt/basalt/.venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/basalt/.venv/bin/pip install --no-cache-dir -r requirements.txt

# serve/ adds its own parent and a sibling tools/ dir to sys.path, so the
# repo-root layout has to be preserved.
COPY --from=build /artifacts/bin/ ./bin/
COPY --from=build /opt/basalt/serve ./serve/
COPY --from=build /opt/basalt/tools ./tools/
COPY --from=build /opt/basalt/data ./data/

ENV PYTHONPATH=/opt/basalt

RUN set -eux; \
    test -x bin/basalt; \
    test -x bin/basalt-vision; \
    unresolved="$(ldd bin/basalt bin/basalt-vision | awk '/not found/ {print}')"; \
    test -z "$unresolved" || { echo "unresolved libraries in the runtime image:"; echo "$unresolved"; exit 1; }; \
    .venv/bin/python -c "import serve.server, serve.frontend; print('server imports ok')"

# Provenance record beside the engine binary. serve/engine/process.py reads
# bin/BUILD.json for the version at startup - the engine's own INFO line wins, so
# this file is the fallback and the machine-readable copy. It answers "which
# commit is this box running" with a docker exec, no registry query:
#   docker exec basalt cat /opt/basalt/bin/BUILD.json
ARG BASALT_BUILD_ID=""
ARG UPSTREAM_SHA=""
ARG CI_RUN=""
ARG CI_BUILDTIME=""
RUN set -eu; \
    if [ -z "${UPSTREAM_SHA}" ]; then echo "no build metadata passed - skipping bin/BUILD.json"; exit 0; fi; \
    printf '{\n  "version": "%s",\n  "upstream_repo": "jesdga95/basalt",\n  "upstream_commit": "%s",\n  "ci_run": "%s",\n  "built": "%s",\n  "cuda_arch": "120"\n}\n' \
      "${BASALT_BUILD_ID}" "${UPSTREAM_SHA}" "${CI_RUN}" "${CI_BUILDTIME}" > bin/BUILD.json; \
    cat bin/BUILD.json

# The model pack and basalt_config.json are NOT baked in. Mount them, and keep
# whatever path the config's "model" key names reachable inside this container.
#   -v /path/to/basalt_config.json:/work/basalt_config.json:ro \
#   -v /path/to/models:/work/models:ro
EXPOSE 8080

ENTRYPOINT ["/opt/basalt/bin/basalt"]
CMD ["--help"]
