# Internal source manifest for the released `rivet::platform` library target.
# This remains the single source of truth for Rivet's own CMake project, but it
# is not a downstream integration surface: applications add_subdirectory the
# installed/released platform package and link `rivet::platform`. They never
# include this fragment or compile these translation units into their own
# executable (issue #238 supersedes the transitional #234 contract).

include_guard(GLOBAL)

set(RIVET_LINUX_PLATFORM_SOURCES
  "${RIVET_ROOT}/platform/linux/chart/chart_area.cpp"
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
  "${RIVET_ROOT}/platform/linux/update/update_handoff.cpp"
  "${RIVET_ROOT}/runtime/src/chart_batch.cpp"
  "${RIVET_ROOT}/runtime/src/protocol.cpp"
)

set(RIVET_LINUX_INCLUDE_DIRS
  "${RIVET_ROOT}/platform/linux/chart"
  "${RIVET_ROOT}/platform/linux/runtime"
  "${RIVET_ROOT}/platform/linux/system"
  "${RIVET_ROOT}/platform/linux/theme"
  "${RIVET_ROOT}/platform/linux/update"
  "${RIVET_ROOT}/runtime/include"
)
