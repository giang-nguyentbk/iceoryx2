# Integrating iceoryx2 into a C++ Project

This guide shows how to use iceoryx2 v0.10.0 from your own C++ project:
how to build it, how to add it to your build system, the C++ code for
inter-thread (ITC) and inter-process communication (IPC), and what the
machine needs at runtime.

Everything in this guide was built and run on Linux (Ubuntu 24.04,
GCC 13, CMake 3.31, Rust 1.99) inside this repository's dev container.
The complete code is in [examples/integration](../../examples/integration),
together with end-to-end tests that `scripts/build.sh` and `scripts/run.sh`
build and run in the dev container.

* [1. How the Pieces Fit Together](#1-how-the-pieces-fit-together)
* [2. Prerequisites on the Build Machine](#2-prerequisites-on-the-build-machine)
* [3. Option A: Install Once, Use `find_package`](#3-option-a-install-once-use-find_package)
* [4. Option B: Build From Source With Your Project](#4-option-b-build-from-source-with-your-project)
* [5. Option C: Bazel](#5-option-c-bazel)
* [6. The C++ Code](#6-the-c-code)
* [7. Environment and Machine Setup](#7-environment-and-machine-setup)
* [8. Troubleshooting](#8-troubleshooting)

## 1. How the Pieces Fit Together

iceoryx2 is implemented in Rust. The C++ API is a thin layer on top of a C
API that the Rust core exports:

```text
your C++ application
        |
        v
iceoryx2-cxx        C++ API: iox2/iceoryx2.hpp   (libiceoryx2_cxx.a / .so)
iceoryx2-bb-cxx     C++ building blocks: Expected, Optional, containers
        |
        v
iceoryx2-c          C API generated from Rust    (libiceoryx2_ffi_c.a / .so)
        |
        v
iceoryx2 (Rust)     the actual implementation, compiled by cargo
```

Consequences for integration:

* The **Rust toolchain is only needed to build** iceoryx2. Applications that
  link the installed libraries need no Rust, neither to compile nor to run.
* With the static libraries the result is a self-contained executable that
  only depends on `libc`, `libm`, `libstdc++` and `libgcc_s`.
* The CMake packages and targets you link against are:
    * `iceoryx2-cxx::static-lib-cxx` - C++ API, static (recommended)
    * `iceoryx2-cxx::shared-lib-cxx` - C++ API, shared
    * `iceoryx2-c::static-lib` / `iceoryx2-c::shared-lib` - the plain C API

## 2. Prerequisites on the Build Machine

Needed wherever iceoryx2 itself is compiled:

* Rust >= 1.89 (the project's minimum supported version), installed with
  [rustup](https://www.rust-lang.org/tools/install)
* CMake >= 3.22
* A C and C++ compiler (GCC or Clang); the C++ API needs C++14 or newer
* `libclang`, used by `bindgen` while compiling the platform layer
* `git` and `curl`

On Ubuntu:

```sh
sudo apt install build-essential clang libclang-dev cmake git curl
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

> [!NOTE]
> In this repository's dev container (`scripts/build_and_run_docker.sh`),
> Rust, compilers and `libclang` are available, but `docker/Dockerfile` does
> not install CMake yet. Add `cmake` to its package list before following
> this guide inside the container.

## 3. Option A: Install Once, Use `find_package`

Recommended for production and for teams: iceoryx2 is built once (or by
CI), installed into a prefix, and every project consumes it like any other
CMake package. Consumers do not need Rust.

### 3.1 Build and Install iceoryx2

Run in the iceoryx2 repository root. `IOX2_PREFIX` is the install location,
e.g. `/opt/iceoryx2` or a directory inside your project's SDK.

```sh
export IOX2_PREFIX=/opt/iceoryx2
B=target/ff/integration      # build directory for the CMake parts

# 1. Rust core and its C API
cargo build --release --package iceoryx2-ffi-c

# 2. CMake helper modules
cmake -S iceoryx2-cmake-modules -B $B/cmake-modules -DCMAKE_INSTALL_PREFIX=$IOX2_PREFIX
cmake --install $B/cmake-modules

# 3. C bindings (packages the library built in step 1)
cmake -S iceoryx2-c -B $B/c \
      -DRUST_BUILD_ARTIFACT_PATH=$PWD/target/release \
      -DCMAKE_PREFIX_PATH=$IOX2_PREFIX -DCMAKE_INSTALL_PREFIX=$IOX2_PREFIX
cmake --build $B/c && cmake --install $B/c

# 4. C++ building blocks
cmake -S iceoryx2-bb/cxx -B $B/bb-cxx -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=$IOX2_PREFIX -DCMAKE_INSTALL_PREFIX=$IOX2_PREFIX
cmake --build $B/bb-cxx -j && cmake --install $B/bb-cxx

# 5. C++ bindings
cmake -S iceoryx2-cxx -B $B/cxx -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=$IOX2_PREFIX -DCMAKE_INSTALL_PREFIX=$IOX2_PREFIX
cmake --build $B/cxx -j && cmake --install $B/cxx
```

The result (about 54 MB):

```text
$IOX2_PREFIX/
├── include/iceoryx2/v0.10.0/     headers (iox2/iceoryx2.hpp, ...)
└── lib/
    ├── libiceoryx2_cxx.a   libiceoryx2_cxx.so
    ├── libiceoryx2_ffi_c.a libiceoryx2_ffi_c.so
    └── cmake/              iceoryx2-cxx, iceoryx2-bb-cxx, iceoryx2-c,
                            iceoryx2-cmake-modules
```

Build-time choices are made here, once, for all consumers:

* **Rust feature flags** are passed to the `cargo build` in step 1, prefixed
  with `iceoryx2/`, e.g.
  `cargo build --release --package iceoryx2-ffi-c --features iceoryx2/dev_permissions`.
* **STL vocabulary types** (`std::optional`, `std::expected` instead of the
  iceoryx2 implementations) are selected with CMake options in steps 4 and 5,
  see
  [how to switch vocabulary types](../user-documentation/how-to-switch-vocabulary-types-for-iceoryx2-cxx.md).
* For a **debug build** of the Rust core, drop `--release` in step 1 and pass
  `$PWD/target/debug` as `RUST_BUILD_ARTIFACT_PATH`.

### 3.2 Use It in Your Project

```cmake
cmake_minimum_required(VERSION 3.22)
project(my_app LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)          # anything >= 14 works
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(iceoryx2-cxx 0.10.0 REQUIRED)

add_executable(my_app src/main.cpp)
target_link_libraries(my_app PRIVATE iceoryx2-cxx::static-lib-cxx)
```

Configure with the install prefix on the search path:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/iceoryx2
cmake --build build
```

The target brings include paths and all system libraries with it; nothing
else has to be added. Your project may use a newer C++ standard than the one
iceoryx2 was compiled with (tested: application in C++17, library in the
default C++14).

### 3.3 Static or Shared

* `iceoryx2-cxx::static-lib-cxx`: about 9.7 MB per executable, nothing to
  deploy besides the executable.
* `iceoryx2-cxx::shared-lib-cxx`: about 120 KB per executable, but
  `libiceoryx2_cxx.so` and `libiceoryx2_ffi_c.so` must be deployed and be
  findable at runtime. CMake sets an RPATH for executables in the build
  tree; for installed executables set `CMAKE_INSTALL_RPATH` (or
  `LD_LIBRARY_PATH`) to the library directory.

## 4. Option B: Build From Source With Your Project

Convenient during development: iceoryx2's CMake runs `cargo` itself, so a
single `cmake --build` builds the Rust core, the bindings and your
application. Every developer and CI machine then needs Rust. iceoryx2 prints
a warning that this is meant for development; for production use option A.

With the sources in your tree (git submodule, vendored copy, ...):

```cmake
# Do not configure iceoryx2's own tests even if this project uses CTest.
# Otherwise BUILD_TESTING=ON makes iceoryx2 download GoogleTest.
set(SAVED_BUILD_TESTING ${BUILD_TESTING})
set(BUILD_TESTING OFF)
add_subdirectory(third_party/iceoryx2 ${CMAKE_BINARY_DIR}/iceoryx2 EXCLUDE_FROM_ALL)
set(BUILD_TESTING ${SAVED_BUILD_TESTING})

target_link_libraries(my_app PRIVATE iceoryx2-cxx::static-lib-cxx)
```

Or downloaded at configure time:

```cmake
include(FetchContent)
FetchContent_Declare(
    iceoryx2
    GIT_REPOSITORY https://github.com/eclipse-iceoryx/iceoryx2.git
    GIT_TAG        v0.10.0
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(iceoryx2)

target_link_libraries(my_app PRIVATE iceoryx2-cxx::static-lib-cxx)
```

Notes:

* `CMAKE_BUILD_TYPE=Debug` builds the Rust core with cargo's debug profile;
  any other build type uses the release profile.
* The Rust feature flags are CMake options here, e.g.
  `-DIOX2_FEATURE_DEV_PERMISSIONS=ON`; the configure step lists all of them.
* The first build compiles the Rust core, which took about 30 s on a
  28-core machine. Rebuilds are incremental.

## 5. Option C: Bazel

The repository is also a Bazel module. Use
[examples/bazel](../../examples/bazel/README.md) as the template and depend on
`@iceoryx2//:iceoryx2-cxx-static` or `@iceoryx2//:iceoryx2-cxx-shared`.

## 6. The C++ Code

The complete sources of this section are in
[examples/integration/cxx_ipc_itc](../../examples/integration/cxx_ipc_itc).
In the dev container, build and test them with
`scripts/build.sh -s cxx_ipc_itc` and `scripts/run.sh -s cxx_ipc_itc`.

### 6.1 Concepts

* **Node**: the entry point of a process (or thread) into iceoryx2. It owns
  the resources and is used for cleanup when a process dies.
* **Service**: a named communication channel with one messaging pattern:
  publish-subscribe, event, request-response or blackboard. Services with
  the same name but different patterns are independent.
* **Port**: an endpoint of a service, e.g. `Publisher` and `Subscriber`, or
  `Notifier` and `Listener`.
* **Service type**: chosen when the node is created, it selects the
  transport. The rest of the code is identical.
    * `ServiceType::Ipc`: shared memory, works across processes.
    * `ServiceType::Local`: heap memory, only within one process (ITC).
      Leaves no files in `/tmp/iceoryx2` or `/dev/shm`.

In C++ **all ports are thread-safe**: they are protected by a mutex, so a
port may be shared between threads (this corresponds to the Rust
`ipc_threadsafe` / `local_threadsafe` service variants). As in the upstream
examples, the code below creates one node per thread.

Every API call returns an `iox2::bb::Expected`. Calling `.value()` on an
error is a fatal contract violation that terminates the process. The
examples use `.value()` for brevity during setup; check `has_value()` where an
error is expected at runtime (see 6.6).

### 6.2 The Payload Type

The payload lives directly in shared memory and is never serialized, so it
must be self-contained: fixed size, no pointers, no heap memory (no
`std::string`, `std::vector`, ...), trivially copyable and trivially
destructible. For variable-size data use `iox2::bb::Slice` (see 6.7) or the
shared-memory containers of iceoryx2-bb-cxx.

`include/sensor_data.hpp`:

```cpp
#ifndef SENSOR_DATA_HPP
#define SENSOR_DATA_HPP

#include <chrono>
#include <cstdint>
#include <type_traits>

// Payload that is transferred via iceoryx2. It lives directly in shared memory,
// therefore it must be self-contained: fixed size, no pointers, no heap
// (no std::string, std::vector, ...), trivially copyable and destructible.
struct SensorData {
    std::uint64_t sequence;
    std::uint64_t timestamp_ns; // send time, used to compute the latency
    float values[16];
};

static_assert(std::is_trivially_copyable<SensorData>::value, "payload must be trivially copyable");
static_assert(std::is_trivially_destructible<SensorData>::value, "payload must be trivially destructible");

// CLOCK_MONOTONIC is system-wide on Linux, so time stamps are comparable
// between threads and between processes.
inline auto now_ns() -> std::uint64_t {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

#endif
```

All participants must use a payload type with the same size and alignment.
To talk to Rust, C or Python applications, also add
`static constexpr const char* IOX2_TYPE_NAME = "SensorData";` with the type
name used on the other side, see
[examples/cxx/cross_language_communication_basics](../../examples/cxx/cross_language_communication_basics).

### 6.3 IPC: Publisher Process

`src/ipc_publisher.cpp` publishes one sample every 500 ms. It writes the data
straight into a loaned shared-memory sample (zero-copy) and then sends an
event, so subscribers can sleep instead of polling.

```cpp
#include "iox2/iceoryx2.hpp"
#include "sensor_data.hpp"

#include <iostream>
#include <utility>

auto main() -> int {
    using namespace iox2;
    set_log_level_from_env_or(LogLevel::Info);

    // 1. A node is the process' entry point into iceoryx2. ServiceType::Ipc
    //    selects the inter-process transport (POSIX shared memory).
    auto node_result =
        NodeBuilder().name(NodeName::create("sensor-publisher").value()).create<ServiceType::Ipc>();
    if (!node_result.has_value()) {
        std::cerr << "failed to create node, error " << static_cast<int>(node_result.error()) << std::endl;
        return 1;
    }
    auto node = std::move(node_result.value());

    // 2. Open the service, or create it if this is the first participant.
    //    The same name is used for the data (publish-subscribe) and for the
    //    wake-up signal (event); services are distinguished by their pattern.
    const auto service_name = ServiceName::create("Integration/SensorData").value();
    auto pubsub = node.service_builder(service_name).publish_subscribe<SensorData>().open_or_create().value();
    auto event = node.service_builder(service_name).event().open_or_create().value();

    auto publisher = pubsub.publisher_builder().create().value();
    auto notifier = event.notifier_builder().create().value();

    // 3. Publish. node.wait() returns an error on SIGINT/SIGTERM, which ends the loop.
    std::uint64_t sequence = 0;
    while (node.wait(bb::Duration::from_millis(500)).has_value()) {
        // Loan a sample: the memory already is in shared memory, nothing is copied.
        auto sample = publisher.loan_uninit().value();
        auto& data = sample.payload_mut();
        data.sequence = sequence;
        for (auto i = 0U; i < 16U; ++i) {
            data.values[i] = static_cast<float>(sequence) * 0.5F;
        }
        data.timestamp_ns = now_ns();

        send(assume_init(std::move(sample))).value();
        notifier.notify().value(); // wake up the subscribers

        std::cout << "sent sample " << sequence << std::endl;
        ++sequence;
    }

    return 0;
}
```

### 6.4 IPC: Subscriber Process

`src/ipc_subscriber.cpp` sleeps on the listener until the publisher notifies
it, then drains all available samples.

```cpp
#include "iox2/iceoryx2.hpp"
#include "sensor_data.hpp"

#include <iostream>
#include <utility>

auto main() -> int {
    using namespace iox2;
    set_log_level_from_env_or(LogLevel::Info);

    auto node = NodeBuilder().name(NodeName::create("sensor-subscriber").value()).create<ServiceType::Ipc>().value();

    const auto service_name = ServiceName::create("Integration/SensorData").value();
    auto pubsub = node.service_builder(service_name).publish_subscribe<SensorData>().open_or_create().value();
    auto event = node.service_builder(service_name).event().open_or_create().value();

    auto subscriber = pubsub.subscriber_builder().create().value();
    auto listener = event.listener_builder().create().value();

    std::cout << "subscriber ready" << std::endl;

    while (node.wait(bb::Duration::zero()).has_value()) {
        // Sleep until the publisher notifies (or 1 s passes): no busy polling.
        // A blocking wait returns ListenerWaitError::InterruptSignal on
        // SIGINT/SIGTERM, so it must not be unwrapped with .value().
        if (!listener.timed_wait([](auto) -> void {}, bb::Duration::from_secs(1)).has_value()) {
            break;
        }

        // Drain everything that arrived. The sample references shared memory
        // directly and is returned to the publisher when it goes out of scope.
        auto sample = subscriber.receive().value();
        while (sample.has_value()) {
            const auto& data = sample->payload();
            std::cout << "received sample " << data.sequence << ", latency " << (now_ns() - data.timestamp_ns)
                      << " ns" << std::endl;
            sample = subscriber.receive().value();
        }
    }

    return 0;
}
```

### 6.5 ITC: Two Threads in One Process

`src/itc_local.cpp` uses exactly the same API. Only the service type changes
to `ServiceType::Local`: the data stays in heap memory and the service is
invisible to other processes.

```cpp
#include "iox2/iceoryx2.hpp"
#include "sensor_data.hpp"

#include <atomic>
#include <iostream>
#include <mutex>
#include <thread>
#include <utility>

namespace {
std::atomic<bool> keep_running { true }; // NOLINT
std::mutex cout_mutex;                   // NOLINT

// Consumer thread: it uses its own node. Same API as for IPC, only the
// service type differs.
void consumer() {
    using namespace iox2;
    auto node = NodeBuilder().name(NodeName::create("consumer-thread").value()).create<ServiceType::Local>().value();

    const auto service_name = ServiceName::create("Integration/SensorData").value();
    auto pubsub = node.service_builder(service_name).publish_subscribe<SensorData>().open_or_create().value();
    auto event = node.service_builder(service_name).event().open_or_create().value();

    auto subscriber = pubsub.subscriber_builder().create().value();
    auto listener = event.listener_builder().create().value();

    while (keep_running.load()) {
        if (!listener.timed_wait([](auto) -> void {}, bb::Duration::from_millis(100)).has_value()) {
            break; // interrupted by a signal
        }

        auto sample = subscriber.receive().value();
        while (sample.has_value()) {
            const auto& data = sample->payload();
            const auto latency_ns = now_ns() - data.timestamp_ns; // before taking the cout lock
            {
                const std::lock_guard<std::mutex> lock(cout_mutex);
                std::cout << "[consumer] sample " << data.sequence << ", latency " << latency_ns << " ns" << std::endl;
            }
            sample = subscriber.receive().value();
        }
    }
}
} // namespace

auto main() -> int {
    using namespace iox2;
    set_log_level_from_env_or(LogLevel::Info);

    // ServiceType::Local: heap memory instead of shared memory, no files in
    // /tmp/iceoryx2; the service is only visible inside this process.
    auto node = NodeBuilder().name(NodeName::create("producer-thread").value()).create<ServiceType::Local>().value();

    const auto service_name = ServiceName::create("Integration/SensorData").value();
    auto pubsub = node.service_builder(service_name).publish_subscribe<SensorData>().open_or_create().value();
    auto event = node.service_builder(service_name).event().open_or_create().value();

    auto publisher = pubsub.publisher_builder().create().value();
    auto notifier = event.notifier_builder().create().value();

    std::thread consumer_thread(consumer);

    for (std::uint64_t sequence = 0; sequence < 5 && node.wait(bb::Duration::from_millis(200)).has_value();
         ++sequence) {
        auto sample = publisher.loan_uninit().value();
        auto& data = sample.payload_mut();
        data.sequence = sequence;
        data.timestamp_ns = now_ns();
        send(assume_init(std::move(sample))).value();
        notifier.notify().value();
        {
            const std::lock_guard<std::mutex> lock(cout_mutex);
            std::cout << "[producer] sent sample " << sequence << std::endl;
        }
    }

    keep_running.store(false);
    consumer_thread.join();
    return 0;
}
```

### 6.6 Build and Run the Sample

The project layout and `CMakeLists.txt` (option A):

```text
my_app/
├── CMakeLists.txt
├── include/sensor_data.hpp
└── src/{ipc_publisher.cpp, ipc_subscriber.cpp, itc_local.cpp}
```

```cmake
cmake_minimum_required(VERSION 3.22)
project(iox2_integration_sample LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(iceoryx2-cxx 0.10.0 REQUIRED)

foreach(app ipc_publisher ipc_subscriber itc_local)
    add_executable(${app} src/${app}.cpp)
    target_include_directories(${app} PRIVATE include)
    target_link_libraries(${app} PRIVATE iceoryx2-cxx::static-lib-cxx)
endforeach()
```

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/iceoryx2
cmake --build build
```

ITC, a single process:

```console
$ ./build/itc_local
[producer] sent sample 0
[consumer] sample 0, latency 75641 ns
[producer] sent sample 1
[consumer] sample 1, latency 110937 ns
...
```

IPC, two terminals (start order does not matter, `open_or_create` handles
both):

```console
terminal 1 $ ./build/ipc_subscriber
subscriber ready
received sample 0, latency 132126 ns
received sample 1, latency 95814 ns

terminal 2 $ ./build/ipc_publisher
sent sample 0
sent sample 1
```

Stop both with `Ctrl+C`; they shut down cleanly and remove their resources.

The warning `No config file was loaded, a config with default values will be
used.` is harmless (see 7.6). Set `IOX2_LOG_LEVEL=Error` to hide it.

> [!NOTE]
> The latencies above (30-160 us) are dominated by waking up a sleeping
> thread through the kernel, not by iceoryx2: the transport itself takes
> about 300 ns (`benchmarks/publish-subscribe`, which busy-polls). For the
> lowest latency, poll `subscriber.receive()` in a loop on a dedicated core
> instead of waiting on a listener, at the cost of a busy CPU. The `WaitSet`
> (see [examples/cxx/event_based_communication](../../examples/cxx/event_based_communication))
> waits on many listeners and deadlines at once.

### 6.7 Useful Variations

Send a copy instead of writing in place, for small payloads:

```cpp
publisher.send_copy(SensorData { 1, now_ns(), {} }).value();
```

Variable-size payloads with a slice. The memory grows on demand:

```cpp
auto service = node.service_builder(name).publish_subscribe<iox2::bb::Slice<uint8_t>>().open_or_create().value();
auto publisher = service.publisher_builder()
                     .initial_max_slice_len(4096)
                     .allocation_strategy(iox2::AllocationStrategy::PowerOfTwo)
                     .create()
                     .value();
auto sample = publisher.loan_slice_uninit(n_bytes).value();
auto initialized = sample.write_from_fn([](auto i) { return static_cast<uint8_t>(i); });
send(std::move(initialized)).value();
```

Quality-of-service settings on the service builder:

```cpp
auto service = node.service_builder(name)
                   .publish_subscribe<SensorData>()
                   .max_publishers(2)
                   .max_subscribers(8)
                   .subscriber_max_buffer_size(16) // samples queued per subscriber
                   .history_size(4)                // samples delivered to late joiners
                   .enable_safe_overflow(true)     // overwrite the oldest sample when full
                   .open_or_create()
                   .value();
```

The process that creates a service fixes its settings; the others must ask
for compatible settings or opening fails. The simplest approach is to give
every participant the same values, e.g. from a shared header. All shared
memory is reserved up front for the worst case these settings allow, so
oversized limits cost memory (see 7.1).

Other patterns, with complete examples in [examples/cxx](../../examples/cxx):
request-response, blackboard (key-value store), events, health monitoring,
discovery and dynamic data.

## 7. Environment and Machine Setup

**Short answer:** on a normal Linux machine where all communicating
processes run as the same user, linking the library is enough. Nothing has
to be installed or configured at runtime, no daemon is needed, and static
executables have no iceoryx2 runtime dependencies. The points below matter
for containers, multiple users, services started by systemd, and large
setups.

### 7.1 Shared Memory: `/dev/shm`

`ServiceType::Ipc` keeps the payload and its management data in POSIX
shared memory, `/dev/shm` on Linux, which is a RAM-backed `tmpfs`.

* Check it exists and has room: `df -h /dev/shm`. Desktop and server
  distributions size it at half the RAM by default.
* The memory is reserved when ports are created, for the worst case of the
  service settings: roughly the payload size times the number of samples
  that can be in flight (subscriber buffers, history, loans) per publisher.

### 7.2 Discovery Files: `/tmp/iceoryx2`

Services and nodes are discovered through small files below
`/tmp/iceoryx2`. It is created automatically; it must be writable and the
same directory for all participants. The location is the `global.root-path`
setting of the config file (7.6).

### 7.3 Users and Permissions

By default iceoryx2 creates all resources accessible to the **owner only**.
Processes of different users therefore cannot connect.

* Production: run all communicating processes as the same user.
* Development, e.g. containers with inconsistent users: build iceoryx2 with
  the `dev_permissions` feature (`--features iceoryx2/dev_permissions` in
  option A, `-DIOX2_FEATURE_DEV_PERMISSIONS=ON` in option B). It makes all
  resources accessible to everyone and must not be used in production.

### 7.4 Docker and Other Containers

* Docker gives each container a 64 MB `/dev/shm`, which is quickly too small.
  Raise it with `--shm-size=1g` (or more).
* `/tmp` inside a container is not a `tmpfs`, which makes the discovery
  files slower; add `--tmpfs /tmp` if many nodes start at once.
* To communicate between containers, or between a container and the host,
  all of them must share both `/dev/shm` and `/tmp/iceoryx2`, for example
  with `-v /dev/shm:/dev/shm -v /tmp/iceoryx2:/tmp/iceoryx2`, and run as the
  same UID (7.3). See [examples/rust/docker](../../examples/rust/docker/README.md).

### 7.5 systemd Services

Two systemd defaults can silently break IPC between services:

* `PrivateTmp=yes` in a unit gives that service its own `/tmp`, so it does
  not see the `/tmp/iceoryx2` of other services. Do not use it for
  communicating services, or move `global.root-path` out of `/tmp` for all
  of them.
* `RemoveIPC=yes` in `logind.conf` removes a regular (non-system) user's
  shared memory when that user's last session ends. Run services as a
  system user, or set `RemoveIPC=no`.

### 7.6 Configuration File and Logging

A config file is optional; without it the defaults are used and a warning
is logged. It is searched in this order:

1. `$PWD/config/iceoryx2.toml`
2. `$HOME/.config/iceoryx2/iceoryx2.toml`
3. `/etc/iceoryx2/iceoryx2.toml`

It sets global values (root path, prefix, cleanup behavior) and the default
service limits. All keys are described in [config/README.md](../../config/README.md).
`iox2 config generate local` writes a file with the defaults.

The log level is read from `IOX2_LOG_LEVEL` (`Trace`, `Debug`, `Info`,
`Warn`, `Error`, `Fatal`) by `set_log_level_from_env_or(...)`.

### 7.7 Large Setups

Event ports (listeners and notifiers) use file descriptors. With many of
them a process can hit the per-process limit; raise it with `ulimit -n` or
`nofile` in `/etc/security/limits.conf`
(see [benchmarks/README.md](../../benchmarks/README.md#event)).

### 7.8 Inspection With the `iox2` CLI

The CLI shows what is running, which is very useful when two processes do
not find each other. Build it once on a machine with Rust:

```sh
cargo build --release --bin iox2 --bin iox2-service --bin iox2-node --bin iox2-config
export PATH=$PWD/target/release:$PATH
```

```console
$ iox2 service list
[
    PublishSubscribe("Integration/SensorData"),
    Event("Integration/SensorData"),
]
$ iox2 node list      # pid, executable and state (alive/dead) of every node
```

If a process crashes, its resources stay behind until another node notices
the dead node; by default this happens whenever a new node is created.

## 8. Troubleshooting

* **The program aborts with `About to access the value of the 'Expected' but
  it contains the error`.** `.value()` was called on a failed result. The
  log line names the error type and the source line. A common case is a
  blocking wait (`listener.timed_wait`, `blocking_wait`, `WaitSet`)
  interrupted by `Ctrl+C`, which returns `ListenerWaitError::InterruptSignal`.
  Check `has_value()` as in 6.4.
* **Opening a service fails with an incompatibility error.** The
  participants disagree on the payload type (size, alignment or name) or on
  service settings. Use the same type and settings everywhere (6.7).
* **Publisher and subscriber run but do not see each other.** Check that
  both use `ServiceType::Ipc` (not `Local`), run as the same user, share
  `/tmp/iceoryx2` and `/dev/shm` (containers, `PrivateTmp`) and use the same
  config. `iox2 service list` run next to each process shows what it sees.
* **Creating a publisher or subscriber fails in a container.** `/dev/shm` is
  probably full; raise `--shm-size`.
* **`find_package(iceoryx2-cxx)` fails.** Pass the install prefix with
  `-DCMAKE_PREFIX_PATH=...`. The package accepts any requested version up to
  the installed one, so `find_package(iceoryx2-cxx 0.11.0)` fails against
  an installed 0.10.0.
