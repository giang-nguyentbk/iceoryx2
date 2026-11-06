#!/usr/bin/env bash
#
# Builds the iceoryx2 example apps used by the end-to-end tests:
#   * the Rust examples (examples/rust/*/test_e2e_*.exp), with cargo,
#     output in target/release or target/debug
#   * the C++ integration examples (examples/integration/*/test_e2e_*.exp),
#     with CMake against the Rust core built by cargo,
#     output in target/examples-integration/<release|debug>/bin
#
# Must be run from the interactive shell of the dev container
# (open one with scripts/build_and_run_docker.sh); it refuses to run on the host.
#
# Usage: scripts/build.sh [options] [-- <extra cargo args>]
#
# Options:
#   -a, --all            build all example apps, Rust and C++ (default)
#   -s, --single <name>  build a single test or group, given as
#                          - a Rust example directory,  e.g. publish_subscribe
#                          - a Rust example binary,     e.g. publish_subscribe_publisher
#                          - an integration example,    e.g. integration/cxx_ipc_itc
#                                                       (or just cxx_ipc_itc)
#                          - an integration executable, e.g. ipc_publisher
#                          - a group: 'rust' or 'integration'
#   -d, --debug          debug build: unoptimized, full debug symbols
#                        (cargo 'dev' profile / CMake 'Debug', in target/debug
#                        and target/examples-integration/debug)
#                        default is an optimized release build
#                        (cargo 'release' profile / CMake 'Release')
#   -r, --rebuild        rebuild from scratch: clean the selected profile first
#                        (cargo profile and, for C++, its CMake build directory)
#   -l, --list           list available tests
#   -h, --help           show this help
#
# Examples:
#   scripts/build.sh                       # release build of all examples
#   scripts/build.sh -d -s publish_subscribe
#   scripts/build.sh -s integration        # all C++ integration examples
#   scripts/build.sh -d -s cxx_ipc_itc
#   scripts/build.sh -r -d -a              # fresh debug build of everything
#   scripts/build.sh -- -j 8               # pass extra arguments to cargo

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { sed -n '3,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

MODE=all
NAME=""
PROFILE=release
REBUILD=false
LIST=false
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)     MODE=all; shift ;;
        -s|--single)  [[ $# -ge 2 && -n "$2" ]] || die "option '$1' requires a test name (see --list)"
                      MODE=single; NAME="$2"; shift 2 ;;
        -d|--debug)   PROFILE=debug; shift ;;
        -r|--rebuild) REBUILD=true; shift ;;
        -l|--list)    LIST=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; EXTRA_ARGS=("$@"); break ;;
        *)            die "unknown option '$1' (try --help)" ;;
    esac
done

if [[ "${LIST}" == true ]]; then
    print_test_list
    exit 0
fi

require_container "${BASH_SOURCE[0]}"

cd "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Collect what to build
# ---------------------------------------------------------------------------
EXAMPLES=()    # Rust examples   (cargo --example)
BINS=()        # Rust binaries   (cargo --bin), needed by the .exp files
CXX_TARGETS=() # CMake targets of examples/integration

add_test() {
    local exp
    exp="$(exp_file_of "$1")"
    if is_integration_test "$1"; then
        CXX_TARGETS+=("${1#integration/}")
    else
        mapfile -t -O "${#EXAMPLES[@]}" EXAMPLES < <(examples_of_dir "$1")
        [[ -n "${exp}" ]] && mapfile -t -O "${#BINS[@]}" BINS < <(exp_bins "${exp}")
    fi
    return 0
}

if [[ "${MODE}" == all ]]; then
    mapfile -t EXAMPLES < <(all_examples)
    while read -r t; do
        mapfile -t -O "${#BINS[@]}" BINS < <(exp_bins "$(exp_file_of "${t}")")
    done < <(list_rust_tests)
    [[ -n "$(list_integration_tests)" ]] && CXX_TARGETS=(all)
    TITLE="all example apps"
else
    if [[ -n "$(examples_of_dir "${NAME}")" ]]; then
        add_test "${NAME}" # Rust example directory (with or without a test)
    elif [[ -n "$(dir_of_example "${NAME}")" ]]; then
        EXAMPLES=("${NAME}") # single Rust example binary
        EXP="$(exp_file_of "$(dir_of_example "${NAME}")")"
        [[ -n "${EXP}" ]] && mapfile -t BINS < <(exp_bins "${EXP}")
    elif [[ -n "$(integration_test_of_bin "${NAME}")" ]]; then
        CXX_TARGETS=("${NAME}") # single integration executable
    elif mapfile -t TESTS < <(select_tests "${NAME}") && [[ ${#TESTS[@]} -gt 0 ]]; then
        for t in "${TESTS[@]}"; do add_test "${t}"; done
    else
        die "unknown test or example '${NAME}' (see 'scripts/build.sh --list')"
    fi
    TITLE="'${NAME}'"
fi

[[ ${#EXAMPLES[@]} -gt 0 || ${#CXX_TARGETS[@]} -gt 0 ]] || die "nothing to build"
mapfile -t BINS < <(printf '%s\n' "${BINS[@]+"${BINS[@]}"}" | sed '/^$/d' | sort -u)

CARGO_PROFILE_ARGS=()
[[ "${PROFILE}" == release ]] && CARGO_PROFILE_ARGS+=(--release)

CARGO_ARGS=("${CARGO_PROFILE_ARGS[@]+"${CARGO_PROFILE_ARGS[@]}"}")
for e in "${EXAMPLES[@]+"${EXAMPLES[@]}"}"; do CARGO_ARGS+=(--example "${e}"); done
for b in "${BINS[@]+"${BINS[@]}"}"; do CARGO_ARGS+=(--bin "${b}"); done

OUT_DIR="$(target_dir_of_profile "${PROFILE}")"
CXX_BUILD_DIR="$(integration_build_dir_of_profile "${PROFILE}")"
CXX_BIN_DIR="$(integration_bin_dir_of_profile "${PROFILE}")"
CMAKE_BUILD_TYPE="$([[ "${PROFILE}" == debug ]] && echo Debug || echo Release)"

if [[ ${#CXX_TARGETS[@]} -gt 0 ]]; then
    command -v cmake >/dev/null ||
        die "'cmake' is not installed in this container; on the host, update the image with: scripts/build_and_run_docker.sh --rebuild-image"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if [[ "${REBUILD}" == true ]]; then
    info "rebuild requested: cleaning the ${PROFILE} profile"
    cargo clean --profile "$([[ "${PROFILE}" == debug ]] && echo dev || echo release)"
    if [[ ${#CXX_TARGETS[@]} -gt 0 ]]; then
        rm -rf "${CXX_BUILD_DIR}"
    fi
fi

START=${SECONDS}

if [[ ${#EXAMPLES[@]} -gt 0 ]]; then
    info "building Rust examples of ${TITLE} (${PROFILE}, $(rustc --version))"
    echo "    examples: ${EXAMPLES[*]}"
    [[ ${#BINS[@]} -gt 0 ]] && echo "    binaries: ${BINS[*]}"
    cargo build "${CARGO_ARGS[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
fi

if [[ ${#CXX_TARGETS[@]} -gt 0 ]]; then
    info "building C++ integration examples of ${TITLE} (${CMAKE_BUILD_TYPE}, $(cmake --version | head -n1))"
    echo "    targets: ${CXX_TARGETS[*]}"

    # 1. The Rust core with its C API (libiceoryx2_ffi_c + generated headers),
    #    built into the same cargo target directory as the Rust examples.
    cargo build ${CARGO_PROFILE_ARGS[@]+"${CARGO_PROFILE_ARGS[@]}"} --package iceoryx2-ffi-c \
        ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

    # 2. The C/C++ bindings and the examples, against that Rust core.
    cmake -S "${INTEGRATION_DIR}" -B "${CXX_BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
        -DRUST_BUILD_ARTIFACT_PATH="${OUT_DIR}"
    cmake --build "${CXX_BUILD_DIR}" --parallel "$(nproc)" --target "${CXX_TARGETS[@]}"
fi

mkdir -p "$(dirname "${LAST_PROFILE_FILE}")"
echo "${PROFILE}" > "${LAST_PROFILE_FILE}"

info "done in $((SECONDS - START))s"
[[ ${#EXAMPLES[@]} -gt 0 ]] && echo "    Rust examples: ${OUT_DIR}/examples/"
[[ ${#CXX_TARGETS[@]} -gt 0 ]] && echo "    C++ examples:  ${CXX_BIN_DIR}/"
if [[ "${PROFILE}" == debug ]]; then
    if [[ ${#EXAMPLES[@]} -gt 0 ]]; then
        echo "    debug with e.g.: gdb --args ${OUT_DIR}/examples/${EXAMPLES[0]}"
    else
        echo "    debug with e.g.: gdb --args ${CXX_BIN_DIR}/$(ls "${CXX_BIN_DIR}" | head -n1)"
    fi
fi
echo "    run tests with:  scripts/run.sh $([[ "${MODE}" == single ]] && echo "-s ${NAME}" || echo "-a")$([[ "${PROFILE}" == debug ]] && echo " -d")"
