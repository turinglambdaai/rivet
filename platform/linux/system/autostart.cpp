#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <stdexcept>

namespace rivet::system {
namespace {

std::string autostart_path(std::string const& application_id) {
  return detail::xdg_config_home() + "/autostart/" +
         detail::sanitize_file_name(application_id) + ".desktop";
}

}  // namespace

using detail::write_all;
using detail::xdg_config_home;

bool Autostart::Enabled(std::string const& application_id) {
  std::string path = autostart_path(application_id);
  int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    if (errno == ENOENT) return false;
    throw std::runtime_error(std::string("autostart check failed: ") +
                             std::strerror(errno));
  }
  std::string contents;
  char buffer[1024];
  while (true) {
    ssize_t received = ::read(fd, buffer, sizeof(buffer));
    if (received < 0) {
      if (errno == EINTR) continue;
      int saved = errno;
      ::close(fd);
      throw std::runtime_error(std::string("autostart read failed: ") +
                               std::strerror(saved));
    }
    if (received == 0) break;
    contents.append(buffer, static_cast<std::size_t>(received));
  }
  ::close(fd);

  // Follow the Desktop Entry spec's disabling keys.
  if (contents.find("Hidden=true") != std::string::npos) return false;
  if (contents.find("X-GNOME-Autostart-enabled=false") != std::string::npos)
    return false;
  return true;
}

void Autostart::SetEnabled(std::string const& application_id,
                           std::string const& executable, bool enabled) {
  std::string path = autostart_path(application_id);
  if (!enabled) {
    if (::unlink(path.c_str()) != 0 && errno != ENOENT)
      throw std::runtime_error(std::string("autostart removal failed: ") +
                               std::strerror(errno));
    return;
  }

  std::string directory = xdg_config_home() + "/autostart";
  ::mkdir(xdg_config_home().c_str(), 0755);
  ::mkdir(directory.c_str(), 0755);

  std::string contents =
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=" + application_id + "\n"
      "Exec=" + executable + "\n"
      "Terminal=false\n"
      "X-GNOME-Autostart-enabled=true\n";
  int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0)
    throw std::runtime_error(std::string("autostart write failed: ") +
                             std::strerror(errno));
  try {
    write_all(fd, contents.data(), contents.size());
  } catch (...) {
    ::close(fd);
    throw;
  }
  ::close(fd);
}



}  // namespace rivet::system
