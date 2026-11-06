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
// Why the integration samples report ~100 us while the benchmark reports
// ~300 ns: the transport is the same, the difference is how the receiver
// learns about a new sample and in what state the CPU is at that moment.
//
// It measures the one-way latency like the samples do (time stamp before
// send, now() - time stamp on receive) and varies
//   * how the receiver waits: blocking on an event listener (wake-up through
//     the kernel) vs. busy polling the subscriber
//   * the gap between samples: 200 ms (like the samples, the receiving core
//     falls asleep) vs. back-to-back (everything stays hot)

#include "iox2/iceoryx2.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {
struct Timestamp {
    static constexpr const char* IOX2_TYPE_NAME = "WakeupLatencyTimestamp";
    std::uint64_t sequence;
    std::uint64_t send_time_ns;
};

auto now_ns() -> std::uint64_t {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

struct Args {
    int samples = 21;   // samples sent with a 200 ms gap
    int burst = 100001; // samples sent back-to-back
};

void usage() {
    std::cout << "Usage: wakeup_latency [options]\n"
                 "  -s, --samples <n>  samples sent with a 200 ms gap (default 21, min 2)\n"
                 "  -b, --burst <n>    samples sent back-to-back (default 100001, min 2)\n";
}

auto parse_args(int argc, char** argv) -> Args {
    Args args;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&]() -> int {
            if (i + 1 >= argc) {
                std::cerr << "missing value for " << arg << std::endl;
                std::exit(1);
            }
            return std::max(2, std::stoi(argv[++i]));
        };
        if (arg == "-s" || arg == "--samples") {
            args.samples = next();
        } else if (arg == "-b" || arg == "--burst") {
            args.burst = next();
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

template <iox2::ServiceType S>
void measure(const char* label, bool blocking, std::chrono::microseconds gap, int count) {
    using namespace iox2;
    auto node = NodeBuilder().create<S>().value();
    auto service_name = ServiceName::create("Integration/WakeupLatency").value();
    auto pubsub = node.service_builder(service_name).template publish_subscribe<Timestamp>().open_or_create().value();
    auto event = node.service_builder(service_name).event().open_or_create().value();
    auto publisher = pubsub.publisher_builder().create().value();
    auto subscriber = pubsub.subscriber_builder().create().value();
    auto notifier = event.notifier_builder().create().value();
    auto listener = event.listener_builder().create().value();

    std::vector<std::uint64_t> latencies;
    latencies.reserve(static_cast<std::size_t>(count));
    std::atomic<int> received { -1 };

    std::thread receiver([&] {
        for (int i = 0; i < count; ++i) {
            while (true) {
                if (blocking) {
                    // sleep until notified (or 100 ms passed)
                    listener.timed_wait([](auto) -> void {}, bb::Duration::from_millis(100)).value();
                }
                auto sample = subscriber.receive().value();
                if (sample.has_value()) {
                    latencies.push_back(now_ns() - sample->payload().send_time_ns);
                    break;
                }
            }
            received.store(i);
        }
    });

    for (int i = 0; i < count; ++i) {
        if (gap.count() > 0) {
            std::this_thread::sleep_for(gap);
        }
        auto sample = publisher.loan_uninit().value();
        sample.payload_mut() = Timestamp { static_cast<std::uint64_t>(i), now_ns() };
        send(assume_init(std::move(sample))).value();
        if (blocking) {
            notifier.notify().value();
        }
        while (received.load() < i) { // one sample in flight at a time
        }
    }
    receiver.join();

    latencies.erase(latencies.begin()); // drop the first (cold) sample
    std::sort(latencies.begin(), latencies.end());
    std::cout << label << "  min " << latencies.front() << " ns, median " << latencies[latencies.size() / 2]
              << " ns, max " << latencies.back() << " ns" << std::endl;
}
} // namespace

auto main(int argc, char** argv) -> int {
    using namespace std::chrono_literals;
    const auto args = parse_args(argc, argv);
    iox2::set_log_level(iox2::LogLevel::Error);

    using iox2::ServiceType;
    measure<ServiceType::Local>("Local blocking wait, 200 ms gap  ", true, 200ms, args.samples);
    measure<ServiceType::Local>("Local busy poll,     200 ms gap  ", false, 200ms, args.samples);
    measure<ServiceType::Local>("Local blocking wait, back-to-back", true, 0us, args.burst);
    measure<ServiceType::Local>("Local busy poll,     back-to-back", false, 0us, args.burst);
    measure<ServiceType::Ipc>("Ipc   blocking wait, 200 ms gap  ", true, 200ms, args.samples);
    measure<ServiceType::Ipc>("Ipc   busy poll,     200 ms gap  ", false, 200ms, args.samples);
    measure<ServiceType::Ipc>("Ipc   blocking wait, back-to-back", true, 0us, args.burst);
    measure<ServiceType::Ipc>("Ipc   busy poll,     back-to-back", false, 0us, args.burst);
    return 0;
}
