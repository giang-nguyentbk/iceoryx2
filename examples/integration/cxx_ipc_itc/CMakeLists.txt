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

foreach(app ipc_publisher ipc_subscriber itc_local)
    add_executable(${app} src/${app}.cpp)
    target_include_directories(${app} PRIVATE include)
    target_link_libraries(${app} PRIVATE iceoryx2-cxx::static-lib-cxx)
endforeach()
target_link_libraries(itc_local PRIVATE Threads::Threads)

iox2_integration_example(cxx_ipc_itc ipc_publisher ipc_subscriber itc_local)
