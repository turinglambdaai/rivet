cmake_minimum_required(VERSION 3.24)
project(rivet-linux-host LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# RIVET_ROOT points at this Rivet checkout (the runtime/ codec is shared
# across platforms). raco rivet build sets it once the Linux path is wired;
# manual builds export it themselves.
if(NOT DEFINED ENV{RIVET_ROOT})
  message(FATAL_ERROR "RIVET_ROOT is not set. Export RIVET_ROOT to a Rivet checkout.")
endif()
set(RIVET_ROOT "$ENV{RIVET_ROOT}")

# RIVET_RACKET_LIB_DIR points at the staged directory containing
# libracketcs for the exact Racket CS installation being embedded, while
# RIVET_RACKET_INCLUDE points at that installation's public embedding headers.
if(NOT DEFINED ENV{RIVET_RACKET_LIB_DIR})
  message(FATAL_ERROR "RIVET_RACKET_LIB_DIR is not set. Point it at the directory containing libracketcs for your Racket CS installation.")
endif()
if(NOT DEFINED ENV{RIVET_RACKET_INCLUDE})
  message(FATAL_ERROR "RIVET_RACKET_INCLUDE is not set. Point it at the Racket include directory.")
endif()

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)
find_library(RACKETCS_LIBRARY
  NAMES racketcs
  PATHS "$ENV{RIVET_RACKET_LIB_DIR}"
  NO_DEFAULT_PATH
  REQUIRED
)

add_executable(RivetHost
  src/main.cpp
  ../runtime/backend.cpp
  "${RIVET_ROOT}/runtime/src/protocol.cpp"
)

target_include_directories(RivetHost PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../runtime"
  "${RIVET_ROOT}/runtime/include"
  "$ENV{RIVET_RACKET_INCLUDE}"
)

target_link_libraries(RivetHost PRIVATE
  PkgConfig::GTK4
  Threads::Threads
  ${CMAKE_DL_LIBS}
  ${RACKETCS_LIBRARY}
)

target_compile_options(RivetHost PRIVATE -Wall -Wextra -Wpedantic)
