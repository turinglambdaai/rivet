cmake_minimum_required(VERSION 3.20)
project(rivet_runtime LANGUAGES CXX)

add_library(rivet_protocol STATIC
  src/protocol.cpp
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
  configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/../tests/protocol-golden.txt
    ${CMAKE_CURRENT_BINARY_DIR}/protocol-golden.txt
    COPYONLY
  )
  add_executable(rivet_protocol_test tests/protocol_test.cpp)
  target_link_libraries(rivet_protocol_test PRIVATE rivet_protocol)
  target_compile_features(rivet_protocol_test PRIVATE cxx_std_17)
  add_test(NAME rivet_protocol_test COMMAND rivet_protocol_test)

  add_executable(rivet_protocol_property_test tests/protocol_property_test.cpp)
  target_link_libraries(rivet_protocol_property_test PRIVATE rivet_protocol)
  target_compile_features(rivet_protocol_property_test PRIVATE cxx_std_17)
  add_test(NAME rivet_protocol_property_test COMMAND rivet_protocol_property_test)
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
