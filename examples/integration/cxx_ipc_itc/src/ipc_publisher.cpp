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
