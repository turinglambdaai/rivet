cmake_minimum_required(VERSION 3.20)
project(RivetLinuxIntegration LANGUAGES CXX)

if(NOT DEFINED RIVET_ROOT)
  message(FATAL_ERROR "RIVET_ROOT is required")
endif()
if(NOT DEFINED RIVET_RACKET_INCLUDE)
  message(FATAL_ERROR "RIVET_RACKET_INCLUDE is required")
endif()
if(NOT DEFINED RIVET_RACKET_LIBRARY)
  message(FATAL_ERROR "RIVET_RACKET_LIBRARY is required")
endif()

find_package(Threads REQUIRED)

add_executable(RivetIntegration
  main.cpp
  ../runtime/backend.cpp
  ${RIVET_ROOT}/runtime/src/protocol.cpp
)

target_compile_features(RivetIntegration PRIVATE cxx_std_17)
target_include_directories(RivetIntegration PRIVATE
  ${RIVET_RACKET_INCLUDE}
  ../runtime
  ${RIVET_ROOT}/runtime/include
)
target_compile_options(RivetIntegration PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(RivetIntegration PRIVATE
  ${RIVET_RACKET_LIBRARY}
  Threads::Threads
  ${CMAKE_DL_LIBS}
  m
)
