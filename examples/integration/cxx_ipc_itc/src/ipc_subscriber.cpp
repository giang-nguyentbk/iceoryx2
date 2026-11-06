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
