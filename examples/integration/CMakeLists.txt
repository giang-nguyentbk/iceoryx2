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

# Stand-alone C++ project that integrates iceoryx2 the way an external
# project would (see doc/integration/cxx-integration-guide.md).
#
# By default iceoryx2 is built from the sources of this repository
# (add_subdirectory, guide option B). Pass
#   -DRUST_BUILD_ARTIFACT_PATH=<repo>/target/release
# to reuse an already built Rust core instead of building it again with cargo
# (that is what scripts/build.sh does), or
#   -DIOX2_INTEGRATION_USE_INSTALLED=ON -DCMAKE_PREFIX_PATH=<install-prefix>
# to use an installed iceoryx2 (guide option A).
#
# All executables end up in <build-dir>/bin.

cmake_minimum_required(VERSION 3.22)
project(iceoryx2_integration_examples LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

option(IOX2_INTEGRATION_USE_INSTALLED "Use an installed iceoryx2 (find_package) instead of the repository sources" OFF)

if(IOX2_INTEGRATION_USE_INSTALLED)
    find_package(iceoryx2-cxx 0.10.0 REQUIRED)
else()
    # Do not configure iceoryx2's own tests even if this project uses CTest.
    set(SAVED_BUILD_TESTING ${BUILD_TESTING})
    set(BUILD_TESTING OFF)
    add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../.. ${CMAKE_BINARY_DIR}/iceoryx2 EXCLUDE_FROM_ALL)
    set(BUILD_TESTING ${SAVED_BUILD_TESTING})
endif()

find_package(Threads REQUIRED)

# iox2_integration_example(<name> <executable>...)
# Groups the executables of one example under a target named after its
# directory, e.g. 'cmake --build <build-dir> --target cxx_ipc_itc'.
function(iox2_integration_example name)
    add_custom_target(${name})
    add_dependencies(${name} ${ARGN})
endfunction()

add_subdirectory(cxx_ipc_itc)
add_subdirectory(cxx_message_contract)
add_subdirectory(cxx_benchmark_publish_subscribe)
add_subdirectory(cxx_wakeup_latency)
