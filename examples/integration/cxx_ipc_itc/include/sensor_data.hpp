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
