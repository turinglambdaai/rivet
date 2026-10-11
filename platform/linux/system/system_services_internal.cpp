#include "system_services_internal.hpp"

#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace rivet::system::detail {

std::string error_message(char const* what, GError* error) {
  std::string message = what;
  if (error) {
    message += ": ";
    message += error->message;
  }
  return message;
}

namespace {

std::string home_directory() {
  char const* home = getenv("HOME");
  if (!home || !*home) throw std::runtime_error("HOME is not set");
  return home;
}

}  // namespace

std::string xdg_config_home() {
  char const* override_path = getenv("XDG_CONFIG_HOME");
  if (override_path && *override_path) return override_path;
  return home_directory() + "/.config";
}

std::string xdg_state_home() {
  char const* override_path = getenv("XDG_STATE_HOME");
  if (override_path && *override_path) return override_path;
  return home_directory() + "/.local/state";
}

std::string sanitize_file_name(std::string const& value) {
  std::string sanitized;
  sanitized.reserve(value.size());
  for (char character : value) {
    bool const allowed = (character >= 'a' && character <= 'z') ||
                         (character >= 'A' && character <= 'Z') ||
                         (character >= '0' && character <= '9') ||
                         character == '.' || character == '_' ||
                         character == '-';
    sanitized.push_back(allowed ? character : '-');
  }
  return sanitized;
}

GDBusConnection* session_bus() {
  static GDBusConnection* connection = [] {
    GError* error = nullptr;
    GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (error) g_error_free(error);
    // A missing session bus is supported. Callers expose the absent desktop
    // capability instead of turning headless execution into startup failure.
    return bus;
  }();
  return connection;
}

void write_all(int fd, void const* data, std::size_t size) {
  char const* bytes = static_cast<char const*>(data);
  while (size > 0) {
    ssize_t written = ::write(fd, bytes, size);
    if (written < 0) {
      if (errno == EINTR) continue;
      throw std::runtime_error(std::string("single-instance write failed: ") +
                               std::strerror(errno));
    }
    bytes += written;
    size -= static_cast<std::size_t>(written);
  }
}

}  // namespace rivet::system::detail
