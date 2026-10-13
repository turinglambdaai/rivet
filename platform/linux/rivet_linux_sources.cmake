# The canonical Linux platform source list for hosts embedding the Rivet
# runtime. This fragment is the single source of truth — rivet adds new
# platform translation units here (clipboard, global shortcuts, file
# dialogs, ...) so downstream CMakeLists that include() it cannot drift
# behind the package and die on undefined references at link time.
#
# Usage in a host CMakeLists (RIVET_ROOT must be set first):
#
#   include("${RIVET_ROOT}/platform/linux/rivet_linux_sources.cmake")
#   add_executable(RivetHost src/main.cpp ${RIVET_LINUX_PLATFORM_SOURCES})
#   target_include_directories(RivetHost PRIVATE
#     "${CMAKE_CURRENT_SOURCE_DIR}" ${RIVET_LINUX_INCLUDE_DIRS}
#     "$ENV{RIVET_RACKET_INCLUDE}")
#
# Downstreams that hand-copy this list instead take ownership of a file
# they cannot see change; every past breakage (global_shortcuts.cpp,
# clipboard.cpp) was that drift.

include_guard(GLOBAL)

set(RIVET_LINUX_PLATFORM_SOURCES
  "${RIVET_ROOT}/platform/linux/runtime/backend.cpp"
  "${RIVET_ROOT}/platform/linux/system/autostart.cpp"
  "${RIVET_ROOT}/platform/linux/system/clipboard.cpp"
  "${RIVET_ROOT}/platform/linux/system/crash_shutdown.cpp"
  "${RIVET_ROOT}/platform/linux/system/file_dialogs.cpp"
  "${RIVET_ROOT}/platform/linux/system/global_shortcuts.cpp"
  "${RIVET_ROOT}/platform/linux/system/notifications.cpp"
  "${RIVET_ROOT}/platform/linux/system/secure_storage.cpp"
  "${RIVET_ROOT}/platform/linux/system/single_instance.cpp"
  "${RIVET_ROOT}/platform/linux/system/system_services.cpp"
  "${RIVET_ROOT}/platform/linux/system/system_services_internal.cpp"
  "${RIVET_ROOT}/platform/linux/system/tray.cpp"
  "${RIVET_ROOT}/platform/linux/theme/theme.cpp"
  "${RIVET_ROOT}/runtime/src/protocol.cpp"
)

set(RIVET_LINUX_INCLUDE_DIRS
  "${RIVET_ROOT}/platform/linux/runtime"
  "${RIVET_ROOT}/platform/linux/system"
  "${RIVET_ROOT}/platform/linux/theme"
  "${RIVET_ROOT}/runtime/include"
)
