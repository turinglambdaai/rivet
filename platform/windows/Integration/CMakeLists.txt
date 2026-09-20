cmake_minimum_required(VERSION 3.20)
project(RivetWindowsIntegration LANGUAGES CXX)

if(NOT DEFINED RIVET_ROOT)
  message(FATAL_ERROR "RIVET_ROOT is required")
endif()
if(NOT DEFINED RIVET_RACKET_INCLUDE)
  message(FATAL_ERROR "RIVET_RACKET_INCLUDE is required")
endif()
if(NOT DEFINED RIVET_RACKET_IMPORT_LIB)
  message(FATAL_ERROR "RIVET_RACKET_IMPORT_LIB is required")
endif()

add_executable(RivetIntegration
  main.cpp
  ../runtime/backend.cpp
  ../runtime/win32_pipe_transport.cpp
  ${RIVET_ROOT}/runtime/src/protocol.cpp
)

target_compile_features(RivetIntegration PRIVATE cxx_std_17)
target_include_directories(RivetIntegration PRIVATE
  ${RIVET_RACKET_INCLUDE}
  ../runtime
  ${RIVET_ROOT}/runtime/include
)
target_link_libraries(RivetIntegration PRIVATE ${RIVET_RACKET_IMPORT_LIB})
