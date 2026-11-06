#!/usr/bin/env bash
#
# Runs the end-to-end tests of the iceoryx2 example apps against the binaries
# built by scripts/build.sh:
#   * Rust examples:           examples/rust/*/test_e2e_*.exp
#   * C++ integration examples: examples/integration/*/test_e2e_*.exp
# Each test starts the example apps (e.g. a publisher and a subscriber) and
# checks their output with `expect`.
#
# Must be run from the interactive shell of the dev container
# (open one with scripts/build_and_run_docker.sh); it refuses to run on the host.
#
# Usage: scripts/run.sh [options]
#
# Options:
#   -a, --all            run all tests, Rust and C++ (default)
#   -s, --single <name>  run a single test or group, given as
#                          - a Rust example directory,  e.g. publish_subscribe
#                          - a Rust example binary,     e.g. publish_subscribe_publisher
#                          - an integration example,    e.g. integration/cxx_ipc_itc
#                                                       (or just cxx_ipc_itc)
#                          - an integration executable, e.g. ipc_publisher
#                          - an .exp file name,         e.g. test_e2e_publish_subscribe
#                          - a group: 'rust' or 'integration'
#   -d, --debug          use the debug binaries
#                        (target/debug, target/examples-integration/debug)
#   -R, --release        use the release binaries
#                        (target/release, target/examples-integration/release)
#                        default: the profile of the last scripts/build.sh run
#   -l, --list           list available tests
#   -h, --help           show this help
#
# Examples:
#   scripts/run.sh                         # run all tests
#   scripts/run.sh -s publish_subscribe
#   scripts/run.sh -d -s event
#   scripts/run.sh -s integration          # all C++ integration tests
#   scripts/run.sh -s cxx_message_contract

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { sed -n '3,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

MODE=all
NAME=""
PROFILE=""
LIST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)     MODE=all; shift ;;
        -s|--single)  [[ $# -ge 2 && -n "$2" ]] || die "option '$1' requires a test name (see --list)"
                      MODE=single; NAME="$2"; shift 2 ;;
        -d|--debug)   PROFILE=debug; shift ;;
        -R|--release) PROFILE=release; shift ;;
        -l|--list)    LIST=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option '$1' (try --help)" ;;
    esac
done

if [[ "${LIST}" == true ]]; then
    print_test_list
    exit 0
fi

require_container "${BASH_SOURCE[0]}"

cd "${REPO_ROOT}"
command -v expect >/dev/null || die "'expect' is not installed"

if [[ -z "${PROFILE}" ]]; then
    PROFILE="$(cat "${LAST_PROFILE_FILE}" 2>/dev/null || echo release)"
fi
BIN_DIR="$(target_dir_of_profile "${PROFILE}")"
CXX_BIN_DIR="$(integration_bin_dir_of_profile "${PROFILE}")"
export IOX2_INTEGRATION_BIN_DIR="${CXX_BIN_DIR}" # read by examples/integration/common.exp

# ---------------------------------------------------------------------------
# Select tests and check that their binaries are built
# ---------------------------------------------------------------------------
if [[ "${MODE}" == all ]]; then
    mapfile -t TESTS < <(list_tests)
    BUILD_HINT="scripts/build.sh -a"
else
    mapfile -t TESTS < <(select_tests "${NAME}" || true)
    [[ ${#TESTS[@]} -gt 0 ]] || die "unknown test '${NAME}' (see 'scripts/run.sh --list')"
    BUILD_HINT="scripts/build.sh -s $([[ ${#TESTS[@]} -eq 1 ]] && echo "${TESTS[0]}" || echo "${NAME}")"
fi
[[ "${PROFILE}" == debug ]] && BUILD_HINT+=" -d"

MISSING=()
for t in "${TESTS[@]}"; do
    exp="$(exp_file_of "${t}")"
    if is_integration_test "${t}"; then
        while read -r b; do
            [[ -n "${b}" && ! -x "${CXX_BIN_DIR}/${b}" ]] && MISSING+=("${CXX_BIN_DIR}/${b}")
        done < <(exp_integration_bins "${exp}")
        continue
    fi
    while read -r e; do
        [[ -n "${e}" && ! -x "${BIN_DIR}/examples/${e}" ]] && MISSING+=("${BIN_DIR}/examples/${e}")
    done < <(exp_examples "${exp}")
    while read -r b; do
        [[ -n "${b}" && ! -x "${BIN_DIR}/${b}" ]] && MISSING+=("${BIN_DIR}/${b}")
    done < <(exp_bins "${exp}")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    printf '  missing: %s\n' "${MISSING[@]}" >&2
    die "${#MISSING[@]} ${PROFILE} binaries are not built yet; run: ${BUILD_HINT}"
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
cleanup_processes() {
    # Kill example apps a failed/aborted test may have left behind.
    local d
    for d in "${BIN_DIR}" "${CXX_BIN_DIR}"; do pkill -TERM -f "^${d}/" 2>/dev/null || true; done
    sleep 0.2
    for d in "${BIN_DIR}" "${CXX_BIN_DIR}"; do pkill -KILL -f "^${d}/" 2>/dev/null || true; done
}
# The flatbuffer tests compile schemas with `flatc` into the source tree;
# remove the *.bfbs files created by this run so the work tree stays clean.
list_bfbs() { find "${EXAMPLES_DIR}" -name '*.bfbs' | sort; }
list_bfbs > "${WORK_DIR}/bfbs.before"
cleanup_generated_files() {
    list_bfbs | comm -13 "${WORK_DIR}/bfbs.before" - | xargs -r rm -f
}
trap 'cleanup_processes; cleanup_generated_files; rm -rf "${WORK_DIR}"' EXIT

info "running ${#TESTS[@]} test(s) with ${PROFILE} binaries"

PASSED=()
FAILED=()
COUNTER=0
for t in "${TESTS[@]}"; do
    COUNTER=$((COUNTER + 1))
    exp="$(exp_file_of "${t}")"
    echo -e "${C_YELLOW}[${COUNTER}/${#TESTS[@]}] RUN${C_OFF}  ${t} (${exp#"${REPO_ROOT}"/})"

    if is_integration_test "${t}"; then
        # Integration tests take their executables from IOX2_INTEGRATION_BIN_DIR.
        script="${exp}"
    else
        # The upstream tests start the apps with `cargo run`, which always uses
        # the dev profile and may trigger a rebuild. Run the prebuilt binaries
        # of the selected profile directly instead.
        script="${WORK_DIR}/$(basename "${exp}")"
        sed -E \
            -e "s#spawn cargo run --example ([A-Za-z0-9_-]+)( --)?#spawn ${BIN_DIR}/examples/\1#" \
            -e "s#spawn cargo run --bin ([A-Za-z0-9_-]+)( --)?#spawn ${BIN_DIR}/\1#" \
            "${exp}" > "${script}"
        grep -q 'cargo run' "${script}" && warn "${t}: some steps still use 'cargo run'"
    fi

    if expect -f "${script}"; then
        echo -e "${C_GREEN}[${COUNTER}/${#TESTS[@]}] PASS${C_OFF} ${t}"
        PASSED+=("${t}")
    else
        echo -e "${C_RED}[${COUNTER}/${#TESTS[@]}] FAIL${C_OFF} ${t}"
        FAILED+=("${t}")
    fi
    cleanup_processes
done

echo ""
echo "-----------------------------------"
echo "Ran ${#TESTS[@]} test(s): ${#PASSED[@]} passed, ${#FAILED[@]} failed (${PROFILE})."
if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf "${C_RED}FAILED${C_OFF} %s\n" "${FAILED[@]}"
    exit 1
fi
echo -e "${C_GREEN}All tests passed!${C_OFF}"
