# Rivet Linux host platform library.
#
# Downstream hosts never compile Rivet sources into their own executable
# source lists (project constraint, issue #238): they add this directory
# and link the target instead —
#
#   add_subdirectory("${RIVET_ROOT}/platform/linux"
#                    "${CMAKE_BINARY_DIR}/rivet-platform-build")
#   target_link_libraries(RivetHost PRIVATE rivet::platform)
#
# RIVET_ROOT (the installed Rivet package) comes from the environment
# that `raco rivet build` exports.
cmake_minimum_required(VERSION 3.24)
project(rivet-platform LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Release artifacts must not embed developer-machine library search paths;
# every linked library (GTK4, GIO, libsecret, curses, LZ4, zlib) is a system
# dependency resolved by the normal loader search on the target machine.
set(CMAKE_SKIP_RPATH TRUE)

# RIVET_ROOT (the installed Rivet package) comes from the environment that
# `raco rivet build` exports; in-repo consumers may pass it as a CMake
# variable instead.
if(NOT DEFINED RIVET_ROOT)
  if(DEFINED ENV{RIVET_ROOT})
    set(RIVET_ROOT "$ENV{RIVET_ROOT}")
  else()
    message(FATAL_ERROR "RIVET_ROOT is not set. Export RIVET_ROOT to the installed Rivet package (raco rivet build does), or pass -DRIVET_ROOT=...")
  endif()
endif()

if(NOT DEFINED RIVET_RACKET_INCLUDE)
  if(DEFINED ENV{RIVET_RACKET_INCLUDE})
    set(RIVET_RACKET_INCLUDE "$ENV{RIVET_RACKET_INCLUDE}")
  else()
    message(FATAL_ERROR "RIVET_RACKET_INCLUDE is not set. Point it at the Racket include directory.")
  endif()
endif()

find_package(PkgConfig REQUIRED)
find_package(Curses REQUIRED)
find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)
find_library(LZ4_LIBRARY NAMES lz4 REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4>=4.10)
pkg_check_modules(GLIB REQUIRED IMPORTED_TARGET gio-2.0)
# The Secret Service adapter is compiled whenever libsecret is present; the
# capability then reports itself at runtime based on service availability.
pkg_check_modules(LIBSECRET IMPORTED_TARGET libsecret-1)

if(DEFINED RIVET_RACKET_LIBRARY)
  set(RACKETCS_LIBRARY "${RIVET_RACKET_LIBRARY}")
elseif(DEFINED ENV{RIVET_RACKET_LIBRARY})
  set(RACKETCS_LIBRARY "$ENV{RIVET_RACKET_LIBRARY}")
elseif(DEFINED RIVET_RACKET_LIB_DIR)
  find_library(RACKETCS_LIBRARY
    NAMES racketcs
    PATHS "${RIVET_RACKET_LIB_DIR}"
    NO_DEFAULT_PATH
    REQUIRED
  )
elseif(DEFINED ENV{RIVET_RACKET_LIB_DIR})
  find_library(RACKETCS_LIBRARY
    NAMES racketcs
    PATHS "$ENV{RIVET_RACKET_LIB_DIR}"
    NO_DEFAULT_PATH
    REQUIRED
  )
else()
  message(FATAL_ERROR "Set RIVET_RACKET_LIBRARY to libracketcs, or RIVET_RACKET_LIB_DIR to its directory.")
endif()

include("${RIVET_ROOT}/platform/linux/rivet_linux_sources.cmake")

add_library(rivet_platform STATIC ${RIVET_LINUX_PLATFORM_SOURCES})
add_library(rivet::platform ALIAS rivet_platform)

target_include_directories(rivet_platform PUBLIC
  ${RIVET_LINUX_INCLUDE_DIRS}
)
target_include_directories(rivet_platform SYSTEM PUBLIC
  "${RIVET_RACKET_INCLUDE}"
)
target_link_libraries(rivet_platform PUBLIC
  PkgConfig::GTK4
  PkgConfig::GLIB
  ${RACKETCS_LIBRARY}
  ZLIB::ZLIB
  ${LZ4_LIBRARY}
  ${CURSES_LIBRARIES}
  Threads::Threads
  ${CMAKE_DL_LIBS}
)
if(LIBSECRET_FOUND)
  target_compile_definitions(rivet_platform PUBLIC RIVET_HAVE_LIBSECRET=1)
  target_link_libraries(rivet_platform PUBLIC PkgConfig::LIBSECRET)
endif()
target_compile_options(rivet_platform PRIVATE -Wall -Wextra -Wpedantic)
