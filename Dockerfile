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
# There is no GPU on a build runner, so nothing here executes the engine. The
# smoke checks below verify the two things this file can actually get wrong: the
# runtime image resolving every shared library the engine links, and the Python
# server importing from the copied tree.

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

WORKDIR /src
COPY . .

# arch 120 (Blackwell) is the only architecture Basalt builds for; CMakeLists.txt
# hard-fails on anything else. Compiling needs no GPU.
RUN cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      -DCMAKE_CUDA_ARCHITECTURES=120 \
    && cmake --build build -j"$(nproc)"

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
COPY --from=build /src/build/bin/ ./bin/
COPY --from=build /src/serve ./serve/
COPY --from=build /src/tools ./tools/
COPY --from=build /src/data ./data/

ENV PYTHONPATH=/opt/basalt

RUN set -eux; \
    unresolved="$(ldd bin/basalt | awk '/not found/ {print}')"; \
    test -z "$unresolved" || { echo "engine has unresolved libraries in the runtime image:"; echo "$unresolved"; exit 1; }; \
    test -x bin/basalt; \
    .venv/bin/python -c "import serve.server, serve.frontend; print('server imports ok')"

# The model pack and basalt_config.json are NOT baked in. Mount them:
#   -v /path/to/models:/models:ro  -v /path/to/config:/work
EXPOSE 8080

ENTRYPOINT ["/opt/basalt/bin/basalt"]
CMD ["--help"]
