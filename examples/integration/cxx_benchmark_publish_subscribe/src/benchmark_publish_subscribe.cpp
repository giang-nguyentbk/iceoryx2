// Copyright (c) 2026 Contributors to the Eclipse Foundation
//
// See the NOTICE file(s) distributed with this work for additional
// information regarding copyright ownership.
//
// This program and the accompanying materials are made available under the
// terms of the Apache Software License 2.0 which is available at
// https://www.apache.org/licenses/LICENSE-2.0, or the MIT license
// which is available at https://opensource.org/licenses/MIT.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT

// C++ port of benchmarks/publish-subscribe (Rust), same measurement method:
// two threads pinned to two CPU cores play ping-pong over the services
// 'a2b' and 'b2a'; latency = total time / (2 * iterations).

#include "iox2/iceoryx2.hpp"

#include <pthread.h>
#include <sched.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <utility>

namespace {

struct Args {
    std::uint64_t iterations = 10000000;
    std::uint64_t payload_size = 8192;
    int cpu_1 = 0;
    int cpu_2 = 1;
    bool send_copy = false;
    bool bench_ipc = false;
    bool bench_local = false;
};

void usage() {
    std::cout << "Usage: benchmark-publish-subscribe-cxx [options]\n"
                 "  -a, --bench-all              run Ipc and Local\n"
                 "      --bench-ipc              run ServiceType::Ipc\n"
                 "      --bench-local            run ServiceType::Local\n"
                 "  -i, --iterations <n>         ping-pong round trips (default 10000000)\n"
                 "  -p, --payload-size <bytes>   payload size (default 8192)\n"
                 "      --send-copy              write the whole payload on every send\n"
                 "      --cpu-core-participant-1 <n>  (default 0)\n"
                 "      --cpu-core-participant-2 <n>  (default 1)\n";
}

auto parse_args(int argc, char** argv) -> Args {
    Args args;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&]() -> const char* {
            if (i + 1 >= argc) {
                std::cerr << "missing value for " << arg << std::endl;
                std::exit(1);
            }
            return argv[++i];
        };
        if (arg == "-a" || arg == "--bench-all") {
            args.bench_ipc = args.bench_local = true;
        } else if (arg == "--bench-ipc") {
            args.bench_ipc = true;
        } else if (arg == "--bench-local") {
            args.bench_local = true;
        } else if (arg == "-i" || arg == "--iterations") {
            args.iterations = std::stoull(next());
        } else if (arg == "-p" || arg == "--payload-size") {
            args.payload_size = std::stoull(next());
        } else if (arg == "--send-copy") {
            args.send_copy = true;
        } else if (arg == "--cpu-core-participant-1") {
            args.cpu_1 = std::stoi(next());
        } else if (arg == "--cpu-core-participant-2") {
            args.cpu_2 = std::stoi(next());
        } else if (arg == "-h" || arg == "--help") {
            usage();
            std::exit(0);
        } else {
            std::cerr << "unknown argument " << arg << std::endl;
            usage();
            std::exit(1);
        }
    }
    return args;
}

void pin_current_thread(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0) {
        std::cerr << "warning: could not pin thread to cpu " << cpu << std::endl;
    }
}

// Minimal spinning barrier (std::barrier needs C++20).
class SpinBarrier {
  public:
    explicit SpinBarrier(int count)
        : m_count(count) {
    }
    void wait() {
        m_arrived.fetch_add(1);
        while (m_arrived.load() < m_count) {
        }
    }

  private:
    int m_count;
    std::atomic<int> m_arrived { 0 };
};

template <iox2::ServiceType S>
auto service_type_name() -> const char* {
    return S == iox2::ServiceType::Ipc ? "iox2::ServiceType::Ipc" : "iox2::ServiceType::Local";
}

template <iox2::ServiceType S>
void perform_benchmark(const Args& args) {
    using namespace iox2;
    using Payload = bb::Slice<std::uint8_t>;

    auto node = NodeBuilder().create<S>().value();

    auto create_service = [&](const char* name) {
        return node.service_builder(ServiceName::create(name).value())
            .template publish_subscribe<Payload>()
            .max_publishers(1)
            .max_subscribers(1)
            .history_size(0)
            .subscriber_max_buffer_size(1)
            .enable_safe_overflow(true)
            .create()
            .value();
    };
    auto service_a2b = create_service("a2b");
    auto service_b2a = create_service("b2a");

    auto sender_a2b = service_a2b.publisher_builder().initial_max_slice_len(args.payload_size).create().value();
    auto receiver_b2a = service_b2a.subscriber_builder().create().value();
    auto sender_b2a = service_b2a.publisher_builder().initial_max_slice_len(args.payload_size).create().value();
    auto receiver_a2b = service_a2b.subscriber_builder().create().value();

    auto loan = [&](auto& publisher) {
        auto sample = publisher.loan_slice_uninit(args.payload_size).value();
        if (args.send_copy) {
            auto payload = sample.payload_mut();
            std::memset(payload.data(), 0, args.payload_size);
        }
        return assume_init(std::move(sample));
    };

    SpinBarrier startup_barrier(3);
    SpinBarrier start_barrier(3);

    std::thread t1([&] {
        pin_current_thread(args.cpu_1);
        startup_barrier.wait();
        start_barrier.wait();

        auto sample = loan(sender_a2b);
        for (std::uint64_t i = 0; i < args.iterations; ++i) {
            send(std::move(sample)).value();
            sample = loan(sender_a2b); // pre-loan the next sample, like the Rust benchmark
            while (!receiver_b2a.receive().value().has_value()) {
            }
        }
    });

    std::thread t2([&] {
        pin_current_thread(args.cpu_2);
        startup_barrier.wait();
        start_barrier.wait();

        for (std::uint64_t i = 0; i < args.iterations; ++i) {
            auto sample = loan(sender_b2a);
            while (!receiver_a2b.receive().value().has_value()) {
            }
            send(std::move(sample)).value();
        }
    });

    startup_barrier.wait();
    const auto start = std::chrono::steady_clock::now();
    start_barrier.wait();

    t1.join();
    t2.join();

    const auto elapsed = std::chrono::steady_clock::now() - start;
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count();
    std::cout << service_type_name<S>() << " ::: Iterations: " << args.iterations
              << ", Time: " << static_cast<double>(ns) / 1e9 << " s, Latency: "
              << static_cast<std::uint64_t>(ns) / (args.iterations * 2) << " ns, Sample Size: " << args.payload_size
              << std::endl;
}

} // namespace

auto main(int argc, char** argv) -> int {
    const auto args = parse_args(argc, argv);
    iox2::set_log_level(iox2::LogLevel::Error);

    if (!args.bench_ipc && !args.bench_local) {
        std::cout << "Please use either '--bench-all' or select a specific benchmark. See '--help' for details."
                  << std::endl;
        return 0;
    }
    if (args.bench_ipc) {
        perform_benchmark<iox2::ServiceType::Ipc>(args);
    }
    if (args.bench_local) {
        perform_benchmark<iox2::ServiceType::Local>(args);
    }
    return 0;
}
