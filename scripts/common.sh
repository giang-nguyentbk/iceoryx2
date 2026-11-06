#!/usr/bin/env bash
#
# Shared helpers for scripts/build.sh and scripts/run.sh (sourced, not run).
#
# Terminology: a "test" is an example directory that ships an end-to-end test
# (test_e2e_*.exp). There are two kinds:
#   * Rust examples under examples/rust/, built with cargo, named after their
#     directory, e.g. 'publish_subscribe' consists of the example binaries
#     publish_subscribe_publisher + publish_subscribe_subscriber and the
#     scenario examples/rust/publish_subscribe/test_e2e_publish_subscribe.exp
#   * C++ integration examples under examples/integration/, built with CMake,
#     named 'integration/<directory>', e.g. 'integration/cxx_ipc_itc'

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
EXAMPLES_DIR="${REPO_ROOT}/examples/rust"
EXAMPLES_MANIFEST="${REPO_ROOT}/examples/Cargo.toml"
INTEGRATION_DIR="${REPO_ROOT}/examples/integration"
LAST_PROFILE_FILE="${REPO_ROOT}/target/.iox2-last-profile"

if [[ -t 1 ]]; then
    C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[1;34m'; C_OFF='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_OFF=''
fi

info() { echo -e "${C_GREEN}==>${C_OFF} $*"; }
warn() { echo -e "${C_YELLOW}warning:${C_OFF} $*" >&2; }
die()  { echo -e "${C_RED}error:${C_OFF} $*" >&2; exit 1; }

# scripts/build.sh and scripts/run.sh are meant to be used from the
# interactive shell of the dev container, never directly on the host.
require_container() {
    if [[ -z "${IOX2_DEV_CONTAINER:-}" ]]; then
        echo -e "${C_RED}error:${C_OFF} $(basename "$1") must be run inside the dev container." >&2
        echo "  Open a shell in it first:  scripts/build_and_run_docker.sh" >&2
        echo "  then run it from there:    scripts/$(basename "$1") ..." >&2
        exit 1
    fi
}

# Prints "<example-name> <example-dir>" for every Rust example declared in
# examples/Cargo.toml.
example_table() {
    awk '
        function flush() { if (name != "" && dir != "") print name, dir; name = ""; dir = "" }
        /^\[\[example\]\]/ { flush(); in_example = 1; next }
        /^\[/              { flush(); in_example = 0; next }
        in_example && /^name[ \t]*=/ { v = $0; sub(/^name[ \t]*=[ \t]*"/, "", v); sub(/".*/, "", v); name = v }
        in_example && /^path[ \t]*=/ {
            v = $0; sub(/^path[ \t]*=[ \t]*"/, "", v); sub(/".*/, "", v)
            n = split(v, parts, "/")
            if (parts[1] == "rust" && n >= 3) dir = parts[2]
        }
        END { flush() }
    ' "${EXAMPLES_MANIFEST}"
}

# All example binary names, or those of one example directory.
examples_of_dir() { example_table | awk -v d="$1" '$2 == d { print $1 }'; }
all_examples()    { example_table | awk '{ print $1 }'; }

# Example directory that contains the given example binary (empty if none).
dir_of_example()  { example_table | awk -v e="$1" '$1 == e { print $2; exit }'; }

is_integration_test() { [[ "$1" == integration/* ]]; }

# The end-to-end test file of a test (empty if none).
exp_file_of() {
    local dir="${EXAMPLES_DIR}/$1"
    is_integration_test "$1" && dir="${INTEGRATION_DIR}/${1#integration/}"
    [[ -n "${1#integration/}" ]] || return 0
    find "${dir}" -maxdepth 1 -type f -name 'test_e2e_*.exp' 2>/dev/null | sort | head -n1
}

# Tests, i.e. example directories that ship an end-to-end test.
tests_in() {
    local exp
    find "$1" -mindepth 2 -maxdepth 2 -type f -name 'test_e2e_*.exp' 2>/dev/null |
        while read -r exp; do echo "$2$(basename "$(dirname "${exp}")")"; done | sort -u
}
list_rust_tests()        { tests_in "${EXAMPLES_DIR}" ""; }
list_integration_tests() { tests_in "${INTEGRATION_DIR}" "integration/"; }
list_tests()             { list_rust_tests; list_integration_tests; }

# Binaries an end-to-end test spawns via `cargo run --example|--bin <name>`.
exp_examples() { grep -oE 'spawn cargo run --example [A-Za-z0-9_-]+' "$1" | awk '{ print $5 }' | sort -u; }
exp_bins()     { grep -oE 'spawn cargo run --bin [A-Za-z0-9_-]+'     "$1" | awk '{ print $5 }' | sort -u; }

# Executables an integration test spawns via `spawn ${BIN_DIR}/<name>`.
exp_integration_bins() { grep -oE 'spawn \$\{?BIN_DIR\}?/[A-Za-z0-9_-]+' "$1" | sed 's#.*/##' | sort -u; }

# The integration test that runs the given executable (empty if none).
integration_test_of_bin() {
    local t
    while read -r t; do
        if exp_integration_bins "$(exp_file_of "${t}")" | grep -qxF "$1"; then echo "${t}"; return 0; fi
    done < <(list_integration_tests)
}

# Maps a user-provided name to a test. Accepted:
#   publish_subscribe              (Rust example directory)
#   publish_subscribe_publisher    (Rust example binary -> its directory)
#   integration/cxx_ipc_itc        (integration example directory)
#   cxx_ipc_itc                    (same, without the prefix)
#   ipc_publisher                  (integration executable -> its directory)
#   test_e2e_publish_subscribe     (name of the .exp file, either kind)
resolve_test() {
    local name="${1%.exp}" dir exp
    name="${name%/}"
    if [[ "${name}" != integration/* && -d "${EXAMPLES_DIR}/${name}" && -n "$(exp_file_of "${name}")" ]]; then
        echo "${name}"; return 0
    fi
    dir="integration/${name#integration/}"
    if [[ -n "$(exp_file_of "${dir}")" ]]; then
        echo "${dir}"; return 0
    fi
    dir="$(dir_of_example "${name}")"
    if [[ -n "${dir}" && -n "$(exp_file_of "${dir}")" ]]; then
        echo "${dir}"; return 0
    fi
    dir="$(integration_test_of_bin "${name}")"
    if [[ -n "${dir}" ]]; then
        echo "${dir}"; return 0
    fi
    exp="$(find "${EXAMPLES_DIR}" -mindepth 2 -maxdepth 2 -type f -name "${name}.exp" | head -n1)"
    if [[ -n "${exp}" ]]; then
        basename "$(dirname "${exp}")"; return 0
    fi
    exp="$(find "${INTEGRATION_DIR}" -mindepth 2 -maxdepth 2 -type f -name "${name}.exp" | head -n1)"
    if [[ -n "${exp}" ]]; then
        echo "integration/$(basename "$(dirname "${exp}")")"; return 0
    fi
    return 1
}

# Maps a user-provided name to one or more tests: the groups 'rust' and
# 'integration', or a single test (see resolve_test).
select_tests() {
    case "$1" in
        rust)                     list_rust_tests ;;
        integration|integration/) list_integration_tests ;;
        *)                        resolve_test "$1" ;;
    esac
}

print_test_list() {
    local t
    echo "Rust example tests (examples/rust/, group 'rust'):"
    while read -r t; do
        printf "  ${C_BLUE}%-46s${C_OFF} %s\n" "${t}" "$(examples_of_dir "${t}" | paste -sd' ')"
    done < <(list_rust_tests)
    echo ""
    echo "C++ integration example tests (examples/integration/, group 'integration'):"
    while read -r t; do
        printf "  ${C_BLUE}%-46s${C_OFF} %s\n" "${t}" "$(exp_integration_bins "$(exp_file_of "${t}")" | paste -sd' ')"
    done < <(list_integration_tests)
}

# Maps the profile name used by the scripts to the cargo target directory.
target_dir_of_profile() {
    case "$1" in
        release) echo "${REPO_ROOT}/target/release" ;;
        debug)   echo "${REPO_ROOT}/target/debug" ;;
        *)       die "unknown profile '$1'" ;;
    esac
}

# CMake build directory of the integration examples for a profile; the
# executables are in its bin/ subdirectory.
integration_build_dir_of_profile() { echo "${REPO_ROOT}/target/examples-integration/$1"; }
integration_bin_dir_of_profile()   { echo "$(integration_build_dir_of_profile "$1")/bin"; }
