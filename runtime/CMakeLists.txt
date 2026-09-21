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
endif()
