#include "update_handoff.hpp"

#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <stdexcept>
#include <system_error>

namespace rivet::update {

LinuxInstallKind DetectLinuxInstallKind(
    std::filesystem::path const& executable,
    char const* appimage_environment) {
  auto const* appimage = appimage_environment;
  if (appimage == nullptr) appimage = std::getenv("APPIMAGE");
  if (appimage != nullptr && appimage[0] != '\0') {
    return LinuxInstallKind::appimage;
  }
  auto normalized = std::filesystem::absolute(executable).lexically_normal();
  auto const text = normalized.generic_string();
  if (text.rfind("/opt/", 0) == 0 || text.rfind("/usr/", 0) == 0) {
    return LinuxInstallKind::package_manager;
  }
  return LinuxInstallKind::portable;
}

[[noreturn]] void RelaunchInstalledAppImage(
    std::filesystem::path const& appimage,
    std::vector<std::string> arguments,
    std::function<void()> release_lease) {
  if (!appimage.is_absolute() || !std::filesystem::is_regular_file(appimage)) {
    throw std::invalid_argument(
        "installed AppImage must be an absolute existing file");
  }
  if (release_lease) release_lease();

  auto executable = appimage.string();
  std::vector<char*> argv;
  argv.reserve(arguments.size() + 2);
  argv.push_back(executable.data());
  for (auto& argument : arguments) argv.push_back(argument.data());
  argv.push_back(nullptr);
  ::execv(executable.c_str(), argv.data());
  throw std::system_error(errno, std::generic_category(),
                          "could not relaunch installed AppImage");
}

}  // namespace rivet::update
