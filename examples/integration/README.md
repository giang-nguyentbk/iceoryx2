# C++ Integration Examples

These examples use iceoryx2 the way an external C++ project does: a
stand-alone CMake project that pulls in the iceoryx2 C++ bindings and links
`iceoryx2-cxx::static-lib-cxx`. They accompany the
[C++ integration guide](../../doc/integration/cxx-integration-guide.md).

| Example | Executables | What it shows |
|---------|-------------|---------------|
| [cxx_ipc_itc](cxx_ipc_itc) | `ipc_publisher`, `ipc_subscriber`, `itc_local` | Event-driven publish-subscribe between processes (IPC) and between threads (ITC) |
| [cxx_message_contract](cxx_message_contract) | `message_contract` | What iceoryx2 checks about the payload type when a peer opens a service |
| [cxx_benchmark_publish_subscribe](cxx_benchmark_publish_subscribe) | `benchmark_publish_subscribe_cxx` | C++ port of `benchmarks/publish-subscribe`: ping-pong latency per payload size |
| [cxx_wakeup_latency](cxx_wakeup_latency) | `wakeup_latency` | Why a blocking wait costs ~100 us while the transport costs ~300 ns |

Each example directory contains its sources, a `CMakeLists.txt` and an
end-to-end test (`test_e2e_*.exp`).

## Build and Run in the Dev Container

Open a shell in the dev container from the host:

```sh
scripts/build_and_run_docker.sh
```

Then, inside the container:

```sh
scripts/build.sh -s integration       # build all integration examples
scripts/run.sh -s integration         # run their end-to-end tests

scripts/build.sh -d -s cxx_ipc_itc    # debug build of one example
scripts/run.sh -s cxx_ipc_itc         # its test (profile of the last build)
scripts/build.sh --list               # all tests, Rust and C++
```

`scripts/build.sh` without options builds the Rust examples and these
examples; `scripts/run.sh` runs all tests. The executables are in
`target/examples-integration/<release|debug>/bin`, e.g.:

```sh
target/examples-integration/release/bin/ipc_subscriber   # terminal 1
target/examples-integration/release/bin/ipc_publisher    # terminal 2
target/examples-integration/release/bin/benchmark_publish_subscribe_cxx \
    --bench-all --payload-size 65536
target/examples-integration/release/bin/wakeup_latency
```

Open a second shell into the running container with
`scripts/build_and_run_docker.sh` from another host terminal.

## Build Without the Scripts

`scripts/build.sh` builds the Rust core with cargo and then this CMake
project against it:

```sh
cargo build --release --package iceoryx2-ffi-c
cmake -S examples/integration -B target/examples-integration/release \
    -DCMAKE_BUILD_TYPE=Release \
    -DRUST_BUILD_ARTIFACT_PATH="$PWD/target/release"
cmake --build target/examples-integration/release --parallel
```

The project supports the integration options of the guide:

* default: iceoryx2 is built from this repository with `add_subdirectory`
  (option B). Without `RUST_BUILD_ARTIFACT_PATH`, CMake runs cargo itself.
* `-DIOX2_INTEGRATION_USE_INSTALLED=ON -DCMAKE_PREFIX_PATH=<prefix>`: use an
  installed iceoryx2 via `find_package` (option A).

## Adding an Example

1. Create `examples/integration/<name>/` with the sources and a
   `CMakeLists.txt` that ends with
   `iox2_integration_example(<name> <executable>...)`.
2. Add `add_subdirectory(<name>)` to
   [CMakeLists.txt](CMakeLists.txt).
3. Add `test_e2e_<name>.exp`. Start the executables with
   `spawn ${BIN_DIR}/<executable>`: `scripts/run.sh` sets `BIN_DIR` to the
   build of the selected profile and checks that these executables exist.
   See [common.exp](common.exp) for the helpers.

The scripts find the new test automatically as `integration/<name>`.
