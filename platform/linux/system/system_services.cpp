#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <stdexcept>

#include <gio/gio.h>

namespace rivet::system {

using detail::session_bus;

std::vector<std::string> ActivationArguments() {
  std::string contents;
  char buffer[4096];
  int fd = ::open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
  if (fd < 0) throw std::runtime_error("could not read /proc/self/cmdline");
  while (true) {
    ssize_t received = ::read(fd, buffer, sizeof(buffer));
    if (received < 0) {
      if (errno == EINTR) continue;
      int saved = errno;
      ::close(fd);
      throw std::runtime_error(std::string("could not read /proc/self/cmdline: ") +
                               std::strerror(saved));
    }
    if (received == 0) break;
    contents.append(buffer, static_cast<std::size_t>(received));
  }
  ::close(fd);

  // Entries are NUL-separated; the first is the executable path itself.
  std::vector<std::string> arguments;
  std::size_t start = 0;
  bool first = true;
  while (start < contents.size()) {
    std::size_t end = contents.find('\0', start);
    if (end == std::string::npos) end = contents.size();
    if (!first) arguments.emplace_back(contents, start, end - start);
    first = false;
    start = end + 1;
  }
  return arguments;
}

namespace {

bool secrets_service_available() {
#if defined(RIVET_HAVE_LIBSECRET)
  static int available_state = -1;  // -1 unknown, 0 no, 1 yes
  if (available_state >= 0) return available_state == 1;
  GDBusConnection* bus = session_bus();
  if (!bus) {
    available_state = 0;
    return false;
  }
  GError* error = nullptr;
  GVariant* owner = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "GetNameOwner", g_variant_new("(s)", "org.freedesktop.secrets"),
      G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  if (!owner) {
    if (error) g_error_free(error);
    available_state = 0;
    return false;
  }
  g_variant_unref(owner);
  available_state = 1;
  return true;
#else
  return false;
#endif
}

}  // namespace

std::vector<std::string> Capabilities() {
  std::vector<std::string> capabilities{"single-instance"};
  if (GlobalShortcuts::available()) capabilities.push_back("global-shortcuts");
  if (Notifications::available()) capabilities.push_back("notification");
  if (TrayIcon::available()) capabilities.push_back("tray");
  capabilities.push_back("autostart");
  if (secrets_service_available()) capabilities.push_back("secure-storage");
  capabilities.push_back("crash-hook");
  return capabilities;
}



}  // namespace rivet::system
