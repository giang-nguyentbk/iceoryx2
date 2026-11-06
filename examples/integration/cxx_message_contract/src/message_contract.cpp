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
// What iceoryx2 checks when peers open a publish-subscribe service: the
// payload type is the contract. The service is created with 'Pose' and then
// opened with differently defined payload types. iceoryx2 compares the type
// name, size and alignment; it cannot see field order or meaning.

#include "iox2/iceoryx2.hpp"

#include <iostream>
#include <string>

namespace {
// The contract the service is created with.
struct Original {
    static constexpr const char* IOX2_TYPE_NAME = "Pose";
    double x;
    double y;
};

// A peer that added a field: other size.
struct ExtraField {
    static constexpr const char* IOX2_TYPE_NAME = "Pose";
    double x;
    double y;
    double z;
};

// Same layout, but another type name.
struct OtherName {
    static constexpr const char* IOX2_TYPE_NAME = "Velocity";
    double x;
    double y;
};

// Same name and size, but stricter alignment.
struct Aligned16 {
    static constexpr const char* IOX2_TYPE_NAME = "Pose";
    alignas(16) double x;
    double y;
};

// Same name, size and alignment, but x and y swapped: not detectable.
struct SwappedFields {
    static constexpr const char* IOX2_TYPE_NAME = "Pose";
    double y;
    double x;
};

const char* const SERVICE_NAME = "Integration/Contract/Pose";

template <typename T>
void try_open(iox2::Node<iox2::ServiceType::Ipc>& node, const std::string& label, const char* note) {
    using namespace iox2;
    auto service =
        node.service_builder(ServiceName::create(SERVICE_NAME).value()).template publish_subscribe<T>().open();

    std::string result = "OK";
    if (!service.has_value()) {
        result = service.error() == PublishSubscribeOpenError::IncompatibleTypes
                     ? "REJECTED (IncompatibleTypes)"
                     : "REJECTED (error " + std::to_string(static_cast<int>(service.error())) + ")";
    }
    std::cout << "open with " << label << " (size " << sizeof(T) << ", align " << alignof(T) << "): " << result
              << note << std::endl;
}
} // namespace

auto main() -> int {
    using namespace iox2;
    // The rejected open() calls would log a warning each; keep the output clean.
    set_log_level(LogLevel::Fatal);

    auto node = NodeBuilder().create<ServiceType::Ipc>().value();
    auto service =
        node.service_builder(ServiceName::create(SERVICE_NAME).value()).publish_subscribe<Original>().create();
    if (!service.has_value()) {
        std::cerr << "failed to create the service, error " << static_cast<int>(service.error()) << std::endl;
        return 1;
    }
    std::cout << "service created with 'Pose' { double x; double y; } (size " << sizeof(Original) << ", align "
              << alignof(Original) << ")" << std::endl;

    try_open<Original>(node, "the same type", "");
    try_open<ExtraField>(node, "an extra field", "");
    try_open<OtherName>(node, "another type name", "");
    try_open<Aligned16>(node, "a stricter alignment", "");
    try_open<SwappedFields>(node, "swapped fields", " <- not detected, x and y would be mixed up");
    return 0;
}
