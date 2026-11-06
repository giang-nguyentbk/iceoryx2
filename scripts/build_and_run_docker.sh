#!/usr/bin/env bash
#
# Builds the minimal iceoryx2 dev image (docker/Dockerfile) if it does not
# exist yet, starts a long-running dev container and runs a command in it.
#
# The container is kept alive between invocations, so several terminals can
# attach to it at the same time and share /dev/shm and /tmp/iceoryx2, which
# iceoryx2 needs for communication between processes (e.g. a publisher in one
# terminal and a subscriber in another).
#
# Usage: scripts/build_and_run_docker.sh [options] [--] [command [args...]]
#   no command      open an interactive bash shell in the container; use
#                   scripts/build.sh and scripts/run.sh from that shell
#   command         run a one-off command in the container instead
#
# Options:
#   --rebuild-image   force a rebuild of the image (and recreate the container)
#   --stop            stop and remove the dev container, then exit
#   -h, --help        show this help
#
# Environment:
#   IOX2_IMAGE        image name           (default: iceoryx2-dev)
#   IOX2_CONTAINER    container name       (default: iceoryx2-dev)
#   IOX2_SHM_SIZE     size of /dev/shm     (default: 2g; Docker's default of
#                                           64m is too small for iceoryx2)
#   RUST_TOOLCHAIN    toolchain for the image build (default: stable)
#   IOX2_NETWORK      network of the image build and of the container
#                     (default: host). Docker's default bridge network has
#                     broken DNS and dropped downloads on this machine, which
#                     breaks apt and cargo. iceoryx2 communicates via shared
#                     memory and files, so it is not affected by this choice.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/docker/Dockerfile"

IMAGE="${IOX2_IMAGE:-iceoryx2-dev}"
CONTAINER="${IOX2_CONTAINER:-iceoryx2-dev}"
SHM_SIZE="${IOX2_SHM_SIZE:-2g}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
NETWORK="${IOX2_NETWORK:-host}"
CARGO_REGISTRY_VOLUME="${CONTAINER}-cargo-registry"
CARGO_GIT_VOLUME="${CONTAINER}-cargo-git"

C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_OFF='\033[0m'

info() { echo -e "${C_GREEN}[docker]${C_OFF} $*" >&2; }
warn() { echo -e "${C_YELLOW}[docker]${C_OFF} $*" >&2; }
die()  { echo -e "${C_RED}[docker] error:${C_OFF} $*" >&2; exit 1; }

usage() {
    sed -n '3,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

if [[ -n "${IOX2_DEV_CONTAINER:-}" ]]; then
    die "already inside the dev container; run the command directly"
fi

REBUILD_IMAGE=false
STOP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild-image) REBUILD_IMAGE=true; shift ;;
        --stop)          STOP=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; break ;;
        -*)              die "unknown option '$1' (try --help)" ;;
        *)               break ;;
    esac
done

command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"

container_exists() { docker container inspect "${CONTAINER}" >/dev/null 2>&1; }

remove_container() {
    if container_exists; then
        info "removing container '${CONTAINER}'"
        docker rm -f "${CONTAINER}" >/dev/null
    fi
}

if [[ "${STOP}" == true ]]; then
    remove_container
    exit 0
fi

# ---------------------------------------------------------------------------
# Image: build if missing, if forced, or if docker/Dockerfile changed
# ---------------------------------------------------------------------------
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
DOCKERFILE_HASH="$( (cat "${DOCKERFILE}"; echo "${HOST_UID}:${HOST_GID}:${RUST_TOOLCHAIN}") | sha256sum | cut -c1-16)"

image_hash() {
    docker image inspect -f '{{ index .Config.Labels "iox2.dockerfile.hash" }}' "${IMAGE}" 2>/dev/null || true
}

if [[ "${REBUILD_IMAGE}" == true ]]; then
    BUILD_REASON="rebuild requested"
elif ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    BUILD_REASON="image '${IMAGE}' does not exist yet"
elif [[ "$(image_hash)" != "${DOCKERFILE_HASH}" ]]; then
    BUILD_REASON="docker/Dockerfile or build settings changed"
else
    BUILD_REASON=""
fi

if [[ -n "${BUILD_REASON}" ]]; then
    info "building image '${IMAGE}' (${BUILD_REASON}) ..."
    BUILD_ARGS=()
    [[ "${REBUILD_IMAGE}" == true ]] && BUILD_ARGS+=(--pull --no-cache)
    if ! docker build "${BUILD_ARGS[@]}" \
        --network "${NETWORK}" \
        --build-arg "USER_UID=${HOST_UID}" \
        --build-arg "USER_GID=${HOST_GID}" \
        --build-arg "RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
        --label "iox2.dockerfile.hash=${DOCKERFILE_HASH}" \
        -t "${IMAGE}" \
        -f "${DOCKERFILE}" \
        "${REPO_ROOT}/docker"; then
        # An update of an existing image failed (e.g. the package mirrors are
        # unreachable): keep working with the old image instead of locking
        # the user out. A forced rebuild or a missing image is still an error.
        if [[ "${REBUILD_IMAGE}" == true ]] || ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
            die "building image '${IMAGE}' failed"
        fi
        warn "updating image '${IMAGE}' failed, continuing with the existing (outdated) image"
        warn "retry later with: scripts/build_and_run_docker.sh --rebuild-image"
    fi
fi

# ---------------------------------------------------------------------------
# Container: (re)create if missing, stale (old image / other repo path), or
# stopped
# ---------------------------------------------------------------------------
IMAGE_ID="$(docker image inspect -f '{{.Id}}' "${IMAGE}")"

if container_exists; then
    C_IMAGE="$(docker container inspect -f '{{.Image}}' "${CONTAINER}")"
    C_REPO="$(docker container inspect -f '{{ index .Config.Labels "iox2.repo" }}' "${CONTAINER}")"
    C_NETWORK="$(docker container inspect -f '{{.HostConfig.NetworkMode}}' "${CONTAINER}")"
    if [[ "${C_IMAGE}" != "${IMAGE_ID}" ]]; then
        warn "container '${CONTAINER}' uses an outdated image, recreating it"
        remove_container
    elif [[ "${C_REPO}" != "${REPO_ROOT}" ]]; then
        warn "container '${CONTAINER}' mounts '${C_REPO}', recreating it for '${REPO_ROOT}'"
        remove_container
    elif [[ "${C_NETWORK}" != "${NETWORK}" ]]; then
        warn "container '${CONTAINER}' uses network '${C_NETWORK}', recreating it with '${NETWORK}'"
        remove_container
    elif [[ "$(docker container inspect -f '{{.State.Running}}' "${CONTAINER}")" != true ]]; then
        info "starting stopped container '${CONTAINER}'"
        docker start "${CONTAINER}" >/dev/null
    fi
fi

if ! container_exists; then
    info "starting container '${CONTAINER}' (repo: ${REPO_ROOT})"
    # - The repo is mounted at the same absolute path as on the host, so paths
    #   in build output, backtraces and debuggers match the host.
    # - /tmp is a tmpfs as iceoryx2 keeps its service/node files in
    #   /tmp/iceoryx2 (see FAQ.md "Docker").
    # - SYS_PTRACE + unconfined seccomp allow gdb to attach and to disable ASLR.
    RUN_ARGS=(--network "${NETWORK}")
    # A custom hostname is not allowed together with the host network.
    [[ "${NETWORK}" != host ]] && RUN_ARGS+=(--hostname "${CONTAINER}")
    docker run -d \
        --name "${CONTAINER}" \
        "${RUN_ARGS[@]}" \
        --label "iox2.repo=${REPO_ROOT}" \
        --init \
        --shm-size="${SHM_SIZE}" \
        --tmpfs /tmp:rw,exec,mode=1777 \
        --cap-add=SYS_PTRACE \
        --security-opt seccomp=unconfined \
        --ulimit core=-1 \
        -v "${REPO_ROOT}:${REPO_ROOT}" \
        -v "${CARGO_REGISTRY_VOLUME}:/home/dev/.cargo/registry" \
        -v "${CARGO_GIT_VOLUME}:/home/dev/.cargo/git" \
        -w "${REPO_ROOT}" \
        "${IMAGE}" \
        sleep infinity >/dev/null
fi

# ---------------------------------------------------------------------------
# Run the command (default: interactive shell)
# ---------------------------------------------------------------------------
# Keep the current directory if it is inside the repo, otherwise use the root.
case "${PWD}/" in
    "${REPO_ROOT}/"*) WORKDIR="${PWD}" ;;
    *)                WORKDIR="${REPO_ROOT}" ;;
esac

EXEC_FLAGS=(-i)
[[ -t 0 && -t 1 ]] && EXEC_FLAGS+=(-t)

if [[ $# -eq 0 ]]; then
    set -- bash
fi

exec docker exec "${EXEC_FLAGS[@]}" \
    -e "TERM=${TERM:-xterm}" \
    -w "${WORKDIR}" \
    "${CONTAINER}" \
    "$@"
