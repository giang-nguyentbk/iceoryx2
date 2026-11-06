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
