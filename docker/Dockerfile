# syntax=docker/dockerfile:1
#
# Minimal development image to build and run the iceoryx2 Rust examples, the
# C++ integration examples and their end-to-end tests
# (examples/rust/*/test_e2e_*.exp, examples/integration/*/test_e2e_*.exp).
#
# The image only contains the toolchain. The repository is bind-mounted at
# runtime by scripts/build_and_run_docker.sh, and the cargo caches live in
# named Docker volumes, so nothing Rust-related is installed on the host.

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# build-essential      : C compiler/linker used by rustc and the `cc` crate
# clang, libclang-dev  : required by `bindgen` in iceoryx2-pal-posix
# cmake                : builds the C/C++ bindings and examples/integration
# libacl1-dev          : POSIX ACL headers used by iceoryx2-pal-posix
# expect               : runs the end-to-end tests (*.exp)
# flatbuffers-compiler : `flatc`, used by the flatbuffer end-to-end tests
# gdb                  : debugging debug builds (scripts/build.sh -d)
# git                  : the *.exp tests locate the repo via `git rev-parse`
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        expect \
        flatbuffers-compiler \
        gdb \
        git \
        less \
        libacl1-dev \
        libclang-dev \
        pkg-config \
        procps \
 && rm -rf /var/lib/apt/lists/*

# Run as a user with the same UID/GID as the host user, so that files written
# to the bind-mounted repository (e.g. target/) are owned by the host user.
# ubuntu:24.04 ships a default 'ubuntu' user with UID 1000; remove it to avoid
# a clash.
ARG USER_UID=1000
ARG USER_GID=1000
RUN set -eux; \
    if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    if ! getent group "${USER_GID}" >/dev/null; then groupadd -g "${USER_GID}" dev; fi; \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash dev

USER dev
WORKDIR /home/dev

ENV RUSTUP_HOME=/home/dev/.rustup \
    CARGO_HOME=/home/dev/.cargo \
    PATH=/home/dev/.cargo/bin:${PATH}

# 'stable' is resolved when the image is built; pass e.g.
# RUST_TOOLCHAIN=1.89.0 (the project MSRV) to scripts/build_and_run_docker.sh
# to pin a specific version.
ARG RUST_TOOLCHAIN=stable
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" --no-modify-path \
 && mkdir -p "${CARGO_HOME}/registry" "${CARGO_HOME}/git" \
 && git config --global --add safe.directory '*' \
 && rustc --version && cargo --version

# Marker used by scripts/build.sh and scripts/run.sh to detect that they are
# already running inside the dev container.
ENV IOX2_DEV_CONTAINER=1

CMD ["bash"]
