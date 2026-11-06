# Copyright (c) 2026 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache Software License 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0, or the MIT license
# which is available at https://opensource.org/licenses/MIT.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

add_executable(benchmark_publish_subscribe_cxx src/benchmark_publish_subscribe.cpp)
target_link_libraries(benchmark_publish_subscribe_cxx PRIVATE iceoryx2-cxx::static-lib-cxx Threads::Threads)

iox2_integration_example(cxx_benchmark_publish_subscribe benchmark_publish_subscribe_cxx)
