cmake_minimum_required(VERSION 3.20)
project(RivetLinuxIntegration LANGUAGES CXX)

# Same policy as the host template: resolve system libraries through the
# normal loader search instead of embedding build-machine runpaths.
set(CMAKE_SKIP_RPATH TRUE)

if(NOT DEFINED RIVET_ROOT)
  message(FATAL_ERROR "RIVET_ROOT is required")
endif()
if(NOT DEFINED RIVET_RACKET_INCLUDE)
  message(FATAL_ERROR "RIVET_RACKET_INCLUDE is required")
endif()
if(NOT DEFINED RIVET_RACKET_LIBRARY)
  message(FATAL_ERROR "RIVET_RACKET_LIBRARY is required")
endif()

find_package(Curses REQUIRED)
find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)
find_library(LZ4_LIBRARY NAMES lz4 REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GLIB REQUIRED IMPORTED_TARGET gio-2.0)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)
# The Secret Service adapter is compiled whenever libsecret is present; the
# capability then reports itself at runtime based on service availability.
pkg_check_modules(LIBSECRET IMPORTED_TARGET libsecret-1)

add_executable(RivetIntegration
  main.cpp
  ../runtime/backend.cpp
  ../system/system_services.cpp
  ${RIVET_ROOT}/runtime/src/protocol.cpp
)

add_executable(RivetThemeTest
  ../theme/theme.cpp
  ../theme/theme_test.cpp
)
target_compile_features(RivetThemeTest PRIVATE cxx_std_17)
target_include_directories(RivetThemeTest PRIVATE ../theme)
target_compile_options(RivetThemeTest PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(RivetThemeTest PRIVATE PkgConfig::GTK4)

if(LIBSECRET_FOUND)
  target_compile_definitions(RivetIntegration PRIVATE RIVET_HAVE_LIBSECRET=1)
endif()

target_compile_features(RivetIntegration PRIVATE cxx_std_17)
target_include_directories(RivetIntegration PRIVATE
  ${RIVET_RACKET_INCLUDE}
  ../runtime
  ../system
  ${RIVET_ROOT}/runtime/include
)
target_compile_options(RivetIntegration PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(RivetIntegration PRIVATE
  ${RIVET_RACKET_LIBRARY}
  ZLIB::ZLIB
  ${LZ4_LIBRARY}
  ${CURSES_LIBRARIES}
  Threads::Threads
  PkgConfig::GLIB
  ${CMAKE_DL_LIBS}
  m
)
if(LIBSECRET_FOUND)
  target_link_libraries(RivetIntegration PRIVATE PkgConfig::LIBSECRET)
endif()
