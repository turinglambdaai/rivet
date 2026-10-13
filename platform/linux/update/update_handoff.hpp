#pragma once

#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace rivet::update {

enum class LinuxInstallKind { appimage, package_manager, portable };

// Mirrors rivet/distribution's installation policy for GTK hosts that need to
// choose localized UI before asking the backend to download anything.
LinuxInstallKind DetectLinuxInstallKind(
    std::filesystem::path const& executable,
    char const* appimage_environment = nullptr);

// Relaunches the AppImage that rivet/distribution has already authenticated
// and atomically installed. `release_lease` runs immediately before exec so a
// single-instance guard cannot reject the new process. This call returns only
// on failure and then throws std::system_error.
[[noreturn]] void RelaunchInstalledAppImage(
    std::filesystem::path const& appimage,
    std::vector<std::string> arguments = {},
    std::function<void()> release_lease = {});

}  // namespace rivet::update
