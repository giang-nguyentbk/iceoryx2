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

add_executable(message_contract src/message_contract.cpp)
target_link_libraries(message_contract PRIVATE iceoryx2-cxx::static-lib-cxx)

iox2_integration_example(cxx_message_contract message_contract)
