cmake_minimum_required(VERSION 3.20)
project(rivet_runtime LANGUAGES CXX)

add_library(rivet_protocol STATIC
  src/protocol.cpp
  src/chart_batch.cpp
  src/sha256.cpp
  src/device_session.cpp
  src/device_session_host.cpp
  src/discovery_advertisement.cpp
  src/utf8.cpp
  src/x509_spki.cpp
)

target_include_directories(rivet_protocol
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_features(rivet_protocol PUBLIC cxx_std_17)

if(MSVC)
  target_compile_options(rivet_protocol PRIVATE /W4 /permissive-)
else()
  target_compile_options(rivet_protocol PRIVATE -Wall -Wextra -Wpedantic)
endif()

option(RIVET_BUILD_TESTS "Build Rivet native runtime tests" ON)
option(RIVET_BUILD_FUZZERS "Build Rivet native protocol fuzz targets" OFF)

if(RIVET_BUILD_TESTS)
  enable_testing()

  # The native tests intentionally use C assertions. CMake's Release flags
  # define NDEBUG by default, which would otherwise turn those checks into
  # no-ops and allow a false-green release build.
  function(rivet_enable_test_assertions target)
    if(MSVC)
      target_compile_options(${target} PRIVATE /UNDEBUG)
    else()
      target_compile_options(${target} PRIVATE -UNDEBUG)
    endif()
  endfunction()

  configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/../rivet/tests/protocol-golden.txt
    ${CMAKE_CURRENT_BINARY_DIR}/protocol-golden.txt
    COPYONLY
  )
  configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/../rivet/tests/device-session-golden.txt
    ${CMAKE_CURRENT_BINARY_DIR}/device-session-golden.txt
    COPYONLY
  )
  add_executable(rivet_protocol_test tests/protocol_test.cpp)
  target_link_libraries(rivet_protocol_test PRIVATE rivet_protocol)
  target_compile_features(rivet_protocol_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_protocol_test)
  add_test(NAME rivet_protocol_test COMMAND rivet_protocol_test)

  add_executable(rivet_device_session_test tests/device_session_test.cpp)
  target_link_libraries(rivet_device_session_test PRIVATE rivet_protocol)
  target_compile_features(rivet_device_session_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_device_session_test)
  add_test(NAME rivet_device_session_test COMMAND rivet_device_session_test)

  add_executable(rivet_device_session_host_test tests/device_session_host_test.cpp)
  target_link_libraries(rivet_device_session_host_test PRIVATE rivet_protocol)
  target_compile_features(rivet_device_session_host_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_device_session_host_test)
  add_test(NAME rivet_device_session_host_test COMMAND rivet_device_session_host_test)

  add_executable(rivet_discovery_advertisement_test tests/discovery_advertisement_test.cpp)
  target_link_libraries(rivet_discovery_advertisement_test PRIVATE rivet_protocol)
  target_compile_features(rivet_discovery_advertisement_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_discovery_advertisement_test)
  add_test(NAME rivet_discovery_advertisement_test COMMAND rivet_discovery_advertisement_test)

  add_executable(rivet_x509_spki_test tests/x509_spki_test.cpp)
  target_link_libraries(rivet_x509_spki_test PRIVATE rivet_protocol)
  target_compile_features(rivet_x509_spki_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_x509_spki_test)
  add_test(NAME rivet_x509_spki_test COMMAND rivet_x509_spki_test)

  add_executable(rivet_protocol_property_test tests/protocol_property_test.cpp)
  target_link_libraries(rivet_protocol_property_test PRIVATE rivet_protocol)
  target_compile_features(rivet_protocol_property_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_protocol_property_test)
  add_test(NAME rivet_protocol_property_test COMMAND rivet_protocol_property_test)

  add_executable(rivet_request_id_allocator_test tests/request_id_allocator_test.cpp)
  target_link_libraries(rivet_request_id_allocator_test PRIVATE rivet_protocol)
  target_compile_features(rivet_request_id_allocator_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_request_id_allocator_test)
  add_test(NAME rivet_request_id_allocator_test COMMAND rivet_request_id_allocator_test)

  add_executable(rivet_pending_request_registry_test tests/pending_request_registry_test.cpp)
  target_link_libraries(rivet_pending_request_registry_test PRIVATE rivet_protocol)
  target_compile_features(rivet_pending_request_registry_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_pending_request_registry_test)
  add_test(NAME rivet_pending_request_registry_test COMMAND rivet_pending_request_registry_test)

  add_executable(rivet_backend_completion_registry_test tests/backend_completion_registry_test.cpp)
  target_link_libraries(rivet_backend_completion_registry_test PRIVATE rivet_protocol)
  target_compile_features(rivet_backend_completion_registry_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_backend_completion_registry_test)
  add_test(NAME rivet_backend_completion_registry_test COMMAND rivet_backend_completion_registry_test)

  add_executable(rivet_chart_batch_test tests/chart_batch_test.cpp)
  target_link_libraries(rivet_chart_batch_test PRIVATE rivet_protocol)
  target_compile_features(rivet_chart_batch_test PRIVATE cxx_std_17)
  rivet_enable_test_assertions(rivet_chart_batch_test)
  add_test(NAME rivet_chart_batch_test COMMAND rivet_chart_batch_test)
endif()

if(RIVET_BUILD_FUZZERS)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "RIVET_BUILD_FUZZERS requires Clang/libFuzzer")
  endif()

  # Instrument the protocol implementation itself for coverage, ASan, and
  # UBSan while leaving the normal library build untouched when fuzzing is off.
  target_compile_options(rivet_protocol PRIVATE
    -fsanitize=fuzzer-no-link,address,undefined
    -fno-omit-frame-pointer
  )

  add_executable(rivet_protocol_fuzz fuzz/protocol_fuzz.cpp)
  target_link_libraries(rivet_protocol_fuzz PRIVATE rivet_protocol)
  target_compile_features(rivet_protocol_fuzz PRIVATE cxx_std_17)
  target_compile_options(rivet_protocol_fuzz PRIVATE
    -fsanitize=fuzzer-no-link,address,undefined
    -fno-omit-frame-pointer
  )
  target_link_options(rivet_protocol_fuzz PRIVATE
    -fsanitize=fuzzer,address,undefined
  )
endif()
