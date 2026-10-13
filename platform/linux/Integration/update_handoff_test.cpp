#include "update_handoff.hpp"

#include <cassert>

int main() {
  using rivet::update::DetectLinuxInstallKind;
  using rivet::update::LinuxInstallKind;

  assert(DetectLinuxInstallKind("/tmp/RivetHost", "/tmp/App.AppImage") ==
         LinuxInstallKind::appimage);
  assert(DetectLinuxInstallKind("/opt/example/RivetHost", "") ==
         LinuxInstallKind::package_manager);
  assert(DetectLinuxInstallKind("/usr/bin/example", "") ==
         LinuxInstallKind::package_manager);
  assert(DetectLinuxInstallKind("./RivetHost", "") ==
         LinuxInstallKind::portable);
}
