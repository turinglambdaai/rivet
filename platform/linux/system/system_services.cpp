#include "system_services.hpp"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <unordered_map>

#include <gio/gio.h>
#include <glib.h>

#if defined(RIVET_HAVE_LIBSECRET)
#include <libsecret/secret.h>
#endif

namespace rivet::system {
namespace {

std::string error_message(char const* what, GError* error) {
  std::string message = what;
  if (error) {
    message += ": ";
    message += error->message;
  }
  return message;
}

std::string home_directory() {
  char const* home = getenv("HOME");
  if (!home || !*home) throw std::runtime_error("HOME is not set");
  return home;
}

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
    bool allowed = (character >= 'a' && character <= 'z') ||
                   (character >= 'A' && character <= 'Z') ||
                   (character >= '0' && character <= '9') ||
                   character == '.' || character == '_' || character == '-';
    sanitized.push_back(allowed ? character : '-');
  }
  return sanitized;
}

std::uint64_t fnv1a(std::string const& value) {
  std::uint64_t hash = 1469598103934665603ull;
  for (unsigned char byte : value) {
    hash ^= byte;
    hash *= 1099511628211ull;
  }
  return hash;
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

void write_size(int fd, std::uint32_t value) {
  write_all(fd, &value, sizeof(value));
}

std::vector<std::string> read_arguments(int fd) {
  auto read_exact = [fd](void* data, std::size_t size) {
    char* bytes = static_cast<char*>(data);
    std::size_t remaining = size;
    while (remaining > 0) {
      ssize_t received = ::read(fd, bytes, remaining);
      if (received == 0)
        throw std::runtime_error("activation stream closed before completion");
      if (received < 0) {
        if (errno == EINTR) continue;
        throw std::runtime_error(std::string("single-instance read failed: ") +
                                 std::strerror(errno));
      }
      bytes += received;
      remaining -= static_cast<std::size_t>(received);
    }
  };
  std::uint32_t count = 0;
  read_exact(&count, sizeof(count));
  if (count > 64) throw std::runtime_error("activation argument count exceeds the limit");
  std::vector<std::string> arguments;
  arguments.reserve(count);
  for (std::uint32_t index = 0; index < count; ++index) {
    std::uint32_t size = 0;
    read_exact(&size, sizeof(size));
    if (size > 4096) throw std::runtime_error("activation argument exceeds the size limit");
    std::string argument(size, '\0');
    if (size > 0) read_exact(argument.data(), size);
    arguments.push_back(std::move(argument));
  }
  return arguments;
}

std::string abstract_lease_name(std::string const& application_id) {
  // Abstract-namespace names are limited to about 107 bytes; long
  // application ids collapse to a bounded prefix plus a stable hash. The
  // leading NUL is what selects the abstract namespace, so the prefix is
  // constructed with an explicit length instead of a strlen'd literal.
  return std::string("\0rivet-single-instance-", 23) +
         application_id.substr(0, 40) + "-" +
         std::to_string(fnv1a(application_id));
}

std::string autostart_path(std::string const& application_id) {
  return xdg_config_home() + "/autostart/" +
         sanitize_file_name(application_id) + ".desktop";
}

GDBusConnection* session_bus() {
  static GDBusConnection* connection = [] {
    GError* error = nullptr;
    GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (error) g_error_free(error);
    // A missing session bus is a supported environment, not a failure: keep
    // the null connection and let callers report the missing capability.
    return bus;
  }();
  return connection;
}

constexpr char const* kNotificationsName = "org.freedesktop.Notifications";
constexpr char const* kNotificationsPath = "/org/freedesktop/Notifications";
constexpr char const* kNotificationsInterface = "org.freedesktop.Notifications";

GVariant* notifications_call(char const* method, GVariant* parameters,
                             GVariantType const* reply_type) {
  GDBusConnection* bus = session_bus();
  if (!bus)
    throw std::runtime_error(
        "notifications are unavailable: no D-Bus session bus is reachable");
  GError* error = nullptr;
  GVariant* reply = g_dbus_connection_call_sync(
      bus, kNotificationsName, kNotificationsPath, kNotificationsInterface,
      method, parameters, reply_type, G_DBUS_CALL_FLAGS_NONE, 2000, nullptr,
      &error);
  if (!reply)
    throw std::runtime_error(error_message("notification call failed", error));
  return reply;
}

std::mutex& notification_tags_mutex() {
  static std::mutex mutex;
  return mutex;
}

std::unordered_map<std::string, std::uint32_t>& notification_tags() {
  static std::unordered_map<std::string, std::uint32_t> tags;
  return tags;
}

// Crash-hook state is written once at install time and only read from the
// signal handler, which must avoid allocations.
int crash_log_fd = -1;
std::string crash_note_suffix;
void (*crash_user_callback)(int) = nullptr;

void write_number_async_signal_safe(int number) {
  char digits[12];
  int length = 0;
  if (number < 0) {
    ssize_t unused = ::write(crash_log_fd, "-", 1);
    (void)unused;
    number = -number;
  }
  do {
    digits[length++] = static_cast<char>('0' + number % 10);
    number /= 10;
  } while (number > 0);
  while (length > 0) {
    ssize_t unused = ::write(crash_log_fd, &digits[--length], 1);
    (void)unused;
  }
}

extern "C" void rivet_crash_signal_handler(int signal_number) {
  if (crash_log_fd >= 0) {
    {
      ssize_t unused = ::write(crash_log_fd, "signal ", 7);
      (void)unused;
    }
    write_number_async_signal_safe(signal_number);
    if (!crash_note_suffix.empty()) {
      ssize_t unused = ::write(crash_log_fd, crash_note_suffix.data(),
                               crash_note_suffix.size());
      (void)unused;
    }
    ssize_t unused = ::write(crash_log_fd, "\n", 1);
    (void)unused;
  }
  if (crash_user_callback) crash_user_callback(signal_number);
  // Chain to the default disposition so core-dump semantics stay honest.
  struct sigaction default_action;
  std::memset(&default_action, 0, sizeof(default_action));
  default_action.sa_handler = SIG_DFL;
  sigaction(signal_number, &default_action, nullptr);
  raise(signal_number);
}

}  // namespace

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

std::vector<std::string> Capabilities() {
  std::vector<std::string> capabilities{"single-instance"};
  if (Notifications::available()) capabilities.push_back("notification");
  if (TrayIcon::available()) capabilities.push_back("tray");
  capabilities.push_back("autostart");
  if (secrets_service_available()) capabilities.push_back("secure-storage");
  capabilities.push_back("crash-hook");
  return capabilities;
}

SingleInstanceLease::SingleInstanceLease(std::string const& application_id)
    : application_id_(application_id) {
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0)
    throw std::runtime_error(std::string("single-instance socket failed: ") +
                             std::strerror(errno));

  std::string name = abstract_lease_name(application_id);
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (name.size() >= sizeof(address.sun_path)) {
    ::close(fd);
    throw std::runtime_error("single-instance lease name exceeds the address limit");
  }
  std::memcpy(address.sun_path, name.data(), name.size());

  socklen_t address_size = static_cast<socklen_t>(
      sizeof(address) - sizeof(address.sun_path) + name.size());
  if (::bind(fd, reinterpret_cast<sockaddr const*>(&address), address_size) == 0) {
    if (::listen(fd, 8) != 0) {
      int saved = errno;
      ::close(fd);
      throw std::runtime_error(std::string("single-instance listen failed: ") +
                               std::strerror(saved));
    }
    socket_fd_ = fd;
    primary_ = true;
    return;
  }
  if (errno == EADDRINUSE) {
    // Another process owns the lease; this instance is a secondary.
    ::close(fd);
    primary_ = false;
    return;
  }
  int saved = errno;
  ::close(fd);
  throw std::runtime_error(std::string("single-instance bind failed: ") +
                           std::strerror(saved));
}

SingleInstanceLease::~SingleInstanceLease() {
  bool was_watching = watcher_.joinable();
  if (was_watching && wakeup_fd_ >= 0) {
    ssize_t unused = ::write(wakeup_fd_, "x", 1);
    (void)unused;
  }
  if (socket_fd_ >= 0) {
    ::close(socket_fd_);
    socket_fd_ = -1;
  }
  if (was_watching) watcher_.join();
  if (wakeup_fd_ >= 0) {
    ::close(wakeup_fd_);
    wakeup_fd_ = -1;
  }
}

bool SingleInstanceLease::forward_arguments(
    std::vector<std::string> const& arguments) const {
  if (primary_)
    throw std::runtime_error("the primary instance cannot forward arguments");
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return false;

  std::string name = abstract_lease_name(application_id_);
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, name.data(), name.size());
  socklen_t address_size = static_cast<socklen_t>(
      sizeof(address) - sizeof(address.sun_path) + name.size());

  if (::connect(fd, reinterpret_cast<sockaddr const*>(&address), address_size) !=
      0) {
    ::close(fd);
    return false;
  }

  try {
    write_size(fd, static_cast<std::uint32_t>(arguments.size()));
    for (std::string const& argument : arguments) {
      write_size(fd, static_cast<std::uint32_t>(argument.size()));
      if (!argument.empty()) write_all(fd, argument.data(), argument.size());
    }
    // Wait for the primary's acknowledgement so a secondary only exits when
    // the activation actually landed.
    pollfd watched{fd, POLLIN, 0};
    int ready = ::poll(&watched, 1, 2000);
    unsigned char acknowledgement = 0;
    if (ready == 1) {
      ssize_t received = ::read(fd, &acknowledgement, 1);
      if (received == 1 && acknowledgement == 0x01) {
        ::close(fd);
        return true;
      }
    }
  } catch (...) {
    ::close(fd);
    return false;
  }
  ::close(fd);
  return false;
}

void SingleInstanceLease::set_activation_handler(ActivationHandler handler) {
  if (!primary_)
    throw std::runtime_error("only the primary instance can watch for activations");
  if (!handler) throw std::runtime_error("activation handler must not be empty");
  if (watcher_.joinable())
    throw std::runtime_error("activation handler is already installed");

  // A close() does not reliably wake a thread blocked in accept(); poll on a
  // self-pipe alongside the listening socket so shutdown is deterministic.
  int pipe_fds[2];
  if (::pipe2(pipe_fds, O_CLOEXEC) != 0)
    throw std::runtime_error(std::string("single-instance pipe failed: ") +
                             std::strerror(errno));
  wakeup_fd_ = pipe_fds[1];

  watching_.store(true);
  int listening_fd = socket_fd_;
  int wake_fd = pipe_fds[0];
  watcher_ = std::thread([this, listening_fd, wake_fd,
                          handler = std::move(handler)]() {
    while (watching_.load()) {
      pollfd watched[2]{{listening_fd, POLLIN, 0}, {wake_fd, POLLIN, 0}};
      int ready = ::poll(watched, 2, -1);
      if (ready <= 0) {
        if (errno == EINTR) continue;
        break;
      }
      if (watched[1].revents != 0) break;  // Wakeup: the lease is shutting down.
      if (watched[0].revents == 0) continue;
      int connection = ::accept(listening_fd, nullptr, nullptr);
      if (connection < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
        break;
      }
      // The abstract namespace has no permission bits, so any local process
      // can connect. Forwarded activations tell the primary which files and
      // URLs to open, which crosses a trust boundary when another user on a
      // shared machine injects them; require the peer to share our uid.
      ucred credentials{};
      socklen_t credentials_size = sizeof(credentials);
      if (::getsockopt(connection, SOL_SOCKET, SO_PEERCRED, &credentials,
                       &credentials_size) != 0 ||
          credentials.uid != ::geteuid()) {
        ::close(connection);
        continue;
      }
      try {
        auto arguments = read_arguments(connection);
        unsigned char acknowledgement = 0x01;
        ssize_t unused = ::write(connection, &acknowledgement, 1);
        (void)unused;
        handler(std::move(arguments));
      } catch (...) {
        // A malformed activation must not take the primary down.
      }
      ::close(connection);
    }
  });
}

#if defined(RIVET_HAVE_LIBSECRET)

SecretSchema const* secret_store_schema() {
  // A process-lifetime schema: libsecret keeps borrowed strings inside.
  static SecretSchema* schema = secret_schema_new(
      "org.rivet.SecretStore", SECRET_SCHEMA_NONE, "service",
      SECRET_SCHEMA_ATTRIBUTE_STRING, "account", SECRET_SCHEMA_ATTRIBUTE_STRING,
      static_cast<void*>(nullptr));
  return schema;
}

GHashTable* secret_store_attributes(std::string const& service,
                                    std::string const& account) {
  GHashTable* attributes =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
  g_hash_table_insert(attributes, g_strdup("service"),
                      g_strdup(service.c_str()));
  g_hash_table_insert(attributes, g_strdup("account"),
                      g_strdup(account.c_str()));
  return attributes;
}

void SecretStore::Set(std::string const& service, std::string const& account,
                      std::vector<std::uint8_t> const& secret) {
  GHashTable* attributes = secret_store_attributes(service, account);
  SecretValue* value = secret_value_new(
      reinterpret_cast<gchar const*>(secret.data()),
      static_cast<gssize>(secret.size()), "application/octet-stream");
  std::string label = "Rivet: " + service + " / " + account;
  GError* error = nullptr;
  gboolean stored = secret_password_storev_binary_sync(
      secret_store_schema(), attributes, SECRET_COLLECTION_DEFAULT,
      label.c_str(), value, nullptr, &error);
  secret_value_unref(value);
  g_hash_table_unref(attributes);
  if (!stored)
    throw std::runtime_error(error_message("secure storage failed", error));
  if (error) g_error_free(error);
}

std::optional<std::vector<std::uint8_t>> SecretStore::Get(
    std::string const& service, std::string const& account) {
  GError* error = nullptr;
  SecretValue* value = secret_password_lookup_binary_sync(
      secret_store_schema(), nullptr, &error, "service", service.c_str(),
      "account", account.c_str(), static_cast<void*>(nullptr));
  if (error) {
    if (value) secret_value_unref(value);
    throw std::runtime_error(
        error_message("secure storage lookup failed", error));
  }
  if (!value) return std::nullopt;
  gsize size = 0;
  gconstpointer data = secret_value_get(value, &size);
  std::vector<std::uint8_t> secret(
      static_cast<std::uint8_t const*>(data),
      static_cast<std::uint8_t const*>(data) + size);
  secret_value_unref(value);
  return secret;
}

void SecretStore::Remove(std::string const& service, std::string const& account) {
  GError* error = nullptr;
  gboolean cleared = secret_password_clear_sync(
      secret_store_schema(), nullptr, &error, "service", service.c_str(),
      "account", account.c_str(), static_cast<void*>(nullptr));
  if (!cleared)
    throw std::runtime_error(
        error_message("secure storage removal failed", error));
  if (error) g_error_free(error);
}

#else

void SecretStore::Set(std::string const&, std::string const&,
                      std::vector<std::uint8_t> const&) {
  throw std::runtime_error(
      "secure storage is unavailable: Rivet was built without libsecret");
}

std::optional<std::vector<std::uint8_t>> SecretStore::Get(std::string const&,
                                                          std::string const&) {
  throw std::runtime_error(
      "secure storage is unavailable: Rivet was built without libsecret");
}

void SecretStore::Remove(std::string const&, std::string const&) {
  throw std::runtime_error(
      "secure storage is unavailable: Rivet was built without libsecret");
}

#endif

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

bool Notifications::available() {
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
      "org.freedesktop.DBus", "GetNameOwner",
      g_variant_new("(s)", kNotificationsName), G_VARIANT_TYPE("(s)"),
      G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  if (!owner) {
    if (error) g_error_free(error);
    available_state = 0;
    return false;
  }
  g_variant_unref(owner);
  available_state = 1;
  return true;
}

std::uint32_t Notifications::Notify(std::string const& application_name,
                                    std::string const& tag,
                                    std::string const& title,
                                    std::string const& body) {
  std::uint32_t replaces_id = 0;
  if (!tag.empty()) {
    std::lock_guard<std::mutex> guard(notification_tags_mutex());
    auto found = notification_tags().find(tag);
    if (found != notification_tags().end()) replaces_id = found->second;
  }

  GVariantBuilder actions_builder;
  g_variant_builder_init(&actions_builder, G_VARIANT_TYPE("as"));
  GVariantBuilder hints_builder;
  g_variant_builder_init(&hints_builder, G_VARIANT_TYPE("a{sv}"));
  GVariant* parameters = g_variant_new(
      "(susssasa{sv}i)", application_name.c_str(), replaces_id, "",
      title.c_str(), body.c_str(), &actions_builder, &hints_builder, -1);
  GVariant* reply =
      notifications_call("Notify", parameters, G_VARIANT_TYPE("(u)"));
  std::uint32_t id = 0;
  g_variant_get(reply, "(u)", &id);
  g_variant_unref(reply);

  if (!tag.empty()) {
    std::lock_guard<std::mutex> guard(notification_tags_mutex());
    notification_tags()[tag] = id;
  }
  return id;
}

void Notifications::Close(std::uint32_t id) {
  GVariant* reply =
      notifications_call("CloseNotification", g_variant_new("(u)", id), nullptr);
  g_variant_unref(reply);
}

void Notifications::CloseTag(std::string const& tag) {
  std::uint32_t id = 0;
  {
    std::lock_guard<std::mutex> guard(notification_tags_mutex());
    auto found = notification_tags().find(tag);
    if (found == notification_tags().end()) return;
    id = found->second;
    notification_tags().erase(found);
  }
  Close(id);
}

// ------------------------------------------------------------------ tray
//
// The tray surface speaks org.kde.StatusNotifierItem plus a
// com.canonical.dbusmenu menu, the pair every Linux desktop watcher hosts
// (GNOME through the AppIndicator extension, KDE natively). Everything below
// runs on the thread-default main context the TrayIcon was constructed on —
// that is where GDBus dispatches property reads, method calls and the
// watcher-restart signal.

namespace {

constexpr char const* kStatusNotifierWatcherName = "org.kde.StatusNotifierWatcher";
constexpr char const* kStatusNotifierWatcherPath = "/StatusNotifierWatcher";

// The interface subsets the desktop watchers actually consume; extra methods
// of the full contracts are omitted rather than stubbed.
constexpr char const* kStatusNotifierItemXml =
    "<node>"
    "<interface name='org.kde.StatusNotifierItem'>"
    "<property name='Id' type='s' access='read'/>"
    "<property name='Category' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/>"
    "<property name='IconName' type='s' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<method name='Activate'>"
    "<arg name='x' type='i' direction='in'/>"
    "<arg name='y' type='i' direction='in'/>"
    "</method>"
    "<method name='SecondaryActivate'>"
    "<arg name='x' type='i' direction='in'/>"
    "<arg name='y' type='i' direction='in'/>"
    "</method>"
    "<method name='Scroll'>"
    "<arg name='delta' type='i' direction='in'/>"
    "<arg name='orientation' type='s' direction='in'/>"
    "</method>"
    "<signal name='NewIcon'/>"
    "<signal name='NewToolTip'/>"
    "</interface>"
    "</node>";

constexpr char const* kDbusMenuXml =
    "<node>"
    "<interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/>"
    "<property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='IconThemePath' type='as' access='read'/>"
    "<method name='GetLayout'>"
    "<arg name='parentId' type='i' direction='in'/>"
    "<arg name='recursionDepth' type='i' direction='in'/>"
    "<arg name='propertyNames' type='as' direction='in'/>"
    "<arg name='revision' type='u' direction='out'/>"
    "<arg name='layout' type='(ia{sv}av)' direction='out'/>"
    "</method>"
    "<method name='GetGroupProperties'>"
    "<arg name='ids' type='ai' direction='in'/>"
    "<arg name='propertyNames' type='as' direction='in'/>"
    "<arg name='properties' type='a(ia{sv})' direction='out'/>"
    "</method>"
    "<method name='GetProperty'>"
    "<arg name='id' type='i' direction='in'/>"
    "<arg name='property' type='s' direction='in'/>"
    "<arg name='value' type='v' direction='out'/>"
    "</method>"
    "<method name='Event'>"
    "<arg name='id' type='i' direction='in'/>"
    "<arg name='eventId' type='s' direction='in'/>"
    "<arg name='data' type='v' direction='in'/>"
    "<arg name='timestamp' type='u' direction='in'/>"
    "</method>"
    "<method name='EventGroup'>"
    "<arg name='events' type='a(isvu)' direction='in'/>"
    "<arg name='idErrors' type='ai' direction='out'/>"
    "</method>"
    "<method name='AboutToShow'>"
    "<arg name='id' type='i' direction='in'/>"
    "<arg name='willShow' type='b' direction='out'/>"
    "</method>"
    "<method name='AboutToShowGroup'>"
    "<arg name='ids' type='ai' direction='in'/>"
    "<arg name='updatesNeeded' type='ai' direction='out'/>"
    "</method>"
    "<signal name='LayoutUpdated'>"
    "<arg name='revision' type='u'/>"
    "<arg name='parent' type='i'/>"
    "</signal>"
    "</interface>"
    "</node>";

GDBusNodeInfo const* status_notifier_item_info() {
  static GDBusNodeInfo* info = [] {
    GDBusNodeInfo* parsed =
        g_dbus_node_info_new_for_xml(kStatusNotifierItemXml, nullptr);
    if (!parsed || !parsed->interfaces[0])
      throw std::runtime_error(
          "the StatusNotifierItem interface description failed to parse");
    return parsed;
  }();
  return info;
}

GDBusNodeInfo const* dbus_menu_info() {
  static GDBusNodeInfo* info = [] {
    GDBusNodeInfo* parsed = g_dbus_node_info_new_for_xml(kDbusMenuXml, nullptr);
    if (!parsed || !parsed->interfaces[0])
      throw std::runtime_error(
          "the com.canonical.dbusmenu interface description failed to parse");
    return parsed;
  }();
  return info;
}

// Object-path element for an application id: D-Bus path elements are
// restricted to [A-Za-z0-9_], so replace everything else. Callers prefix a
// literal segment, so a leading digit in the id cannot survive.
std::string sanitize_path_element(std::string const& application_id) {
  std::string element;
  element.reserve(application_id.size());
  for (char character : application_id) {
    element +=
        (std::isalnum(static_cast<unsigned char>(character)) || character == '_')
            ? character
            : '_';
  }
  return element;
}

}  // namespace

TrayMenuItem::TrayMenuItem(std::string label, std::function<void()> activated,
                           bool enabled)
    : type(Type::item),
      label(std::move(label)),
      enabled(enabled),
      activated(std::move(activated)) {}

struct TrayIcon::Impl {
  std::string id;
  std::string title;
  std::string icon_name;
  std::string tooltip_title;
  std::string tooltip_body;
  std::string object_path;
  std::string menu_path;
  GDBusConnection* bus = nullptr;
  guint sni_registration = 0;
  guint menu_registration = 0;
  guint watcher_subscription = 0;
  std::function<void()> activation_handler;

  std::mutex mutex;  // guards items and revision
  std::vector<TrayMenuItem> items;
  std::uint32_t revision = 1;

  ~Impl() {
    if (watcher_subscription)
      g_dbus_connection_signal_unsubscribe(bus, watcher_subscription);
    if (menu_registration)
      g_dbus_connection_unregister_object(bus, menu_registration);
    if (sni_registration)
      g_dbus_connection_unregister_object(bus, sni_registration);
  }

  void emit_sni_signal(char const* signal_name) {
    g_dbus_connection_emit_signal(bus, nullptr, object_path.c_str(),
                                  "org.kde.StatusNotifierItem", signal_name,
                                  nullptr, nullptr);
  }

  // (Re-)announce this item to the watcher. Runs again whenever the watcher
  // reappears (GNOME Shell restarts, extension reloads), which otherwise
  // leaves a surviving process without its icon.
  void register_with_watcher() {
    GError* error = nullptr;
    GVariant* result = g_dbus_connection_call_sync(
        bus, kStatusNotifierWatcherName, kStatusNotifierWatcherPath,
        kStatusNotifierWatcherName, "RegisterStatusNotifierItem",
        g_variant_new("(s)", object_path.c_str()), nullptr,
        G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &error);
    if (!result) {
      std::string message = error_message("tray registration failed", error);
      throw std::runtime_error(message);
    }
    g_variant_unref(result);
  }

  // GDBus dispatches property reads, method calls and the watcher-restart
  // signal on the thread-default main context the icon was constructed on;
  // the callbacks are members so they can reach this private implementation.
  static GVariant* sni_get_property(GDBusConnection*, gchar const*,
                                    gchar const*, gchar const*,
                                    gchar const* property_name, GError**,
                                    gpointer user_data);
  static void sni_method_call(GDBusConnection*, gchar const*, gchar const*,
                              gchar const*, gchar const* method_name,
                              GVariant*, GDBusMethodInvocation* invocation,
                              gpointer user_data);
  static GVariant* menu_get_property(GDBusConnection*, gchar const*,
                                     gchar const*, gchar const*,
                                     gchar const* property_name, GError**,
                                     gpointer user_data);
  static void menu_method_call(GDBusConnection*, gchar const*, gchar const*,
                               gchar const*, gchar const* method_name,
                               GVariant* parameters,
                               GDBusMethodInvocation* invocation,
                               gpointer user_data);
  static void watcher_owner_changed(GDBusConnection*, gchar const*,
                                    gchar const*, gchar const*, gchar const*,
                                    GVariant* parameters, gpointer user_data);

  static constexpr GDBusInterfaceVTable sni_vtable{
      &Impl::sni_method_call, &Impl::sni_get_property, nullptr, {}};
  static constexpr GDBusInterfaceVTable menu_vtable{
      &Impl::menu_method_call, &Impl::menu_get_property, nullptr, {}};

  // Caller holds mutex. The (a{sv}) property dictionary of one menu entry.
  GVariant* item_properties(gint item_id) {
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
    if (item_id == 0) {
      g_variant_builder_add(&properties, "{sv}", "children-display",
                            g_variant_new_string("submenu"));
      return g_variant_builder_end(&properties);
    }
    TrayMenuItem const& item = items.at(static_cast<std::size_t>(item_id - 1));
    if (item.type == TrayMenuItem::Type::separator) {
      g_variant_builder_add(&properties, "{sv}", "type",
                            g_variant_new_string("separator"));
    } else {
      g_variant_builder_add(&properties, "{sv}", "type",
                            g_variant_new_string("standard"));
      g_variant_builder_add(&properties, "{sv}", "label",
                            g_variant_new_string(item.label.c_str()));
      g_variant_builder_add(&properties, "{sv}", "enabled",
                            g_variant_new_boolean(item.enabled));
    }
    g_variant_builder_add(&properties, "{sv}", "visible",
                          g_variant_new_boolean(true));
    return g_variant_builder_end(&properties);
  }

  // Caller holds mutex. One (ia{sv}av) layout node: the entry's id and
  // properties plus its children — only the root (id 0) has children, the
  // menu is flat.
  GVariant* layout_node(gint item_id) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    if (item_id == 0) {
      for (gint child = 1; child <= static_cast<gint>(items.size()); ++child) {
        g_variant_builder_add_value(
            &children, g_variant_new_variant(layout_node(child)));
      }
    }
    // @-annotate the pre-built property dictionary: bare array/dict format
    // positions expect a GVariantBuilder, not a GVariant.
    return g_variant_new("(i@a{sv}av)", item_id, item_properties(item_id),
                         &children);
  }

  void dispatch_event(gint item_id, gchar const* event_id) {
    if (std::strcmp(event_id, "clicked") != 0) return;
    TrayMenuItem item_copy;
    {
      std::lock_guard<std::mutex> guard(mutex);
      if (item_id < 1 || item_id > static_cast<gint>(items.size())) return;
      item_copy = items[static_cast<std::size_t>(item_id - 1)];
    }
    if (item_copy.type != TrayMenuItem::Type::item || !item_copy.enabled) return;
    if (item_copy.activated) {
      try {
        item_copy.activated();
      } catch (...) {
        // A throwing menu callback must not take the process down inside a
        // GDBus dispatch.
      }
    }
  }
};

GVariant* TrayIcon::Impl::sni_get_property(GDBusConnection*, gchar const*,
                                           gchar const*, gchar const*,
                                           gchar const* property_name,
                                           GError**, gpointer user_data) {
  Impl* impl = static_cast<Impl*>(user_data);
  std::string const name = property_name;
  if (name == "Id") return g_variant_new_string(impl->id.c_str());
  if (name == "Category") return g_variant_new_string("ApplicationStatus");
  if (name == "Status") return g_variant_new_string("Active");
  if (name == "Title") return g_variant_new_string(impl->title.c_str());
  if (name == "IconName") return g_variant_new_string(impl->icon_name.c_str());
  if (name == "ToolTip") {
    // KDbusToolTipStruct: (icon name, pixmap array, title, description).
    GVariantBuilder pixmaps;
    g_variant_builder_init(&pixmaps, G_VARIANT_TYPE("a(iiay)"));
    return g_variant_new("(sa(iiay)ss)", impl->icon_name.c_str(), &pixmaps,
                         impl->tooltip_title.c_str(),
                         impl->tooltip_body.c_str());
  }
  if (name == "Menu") return g_variant_new_object_path(impl->menu_path.c_str());
  return nullptr;
}

void TrayIcon::Impl::sni_method_call(GDBusConnection*, gchar const*,
                                     gchar const*, gchar const*,
                                     gchar const* method_name, GVariant*,
                                     GDBusMethodInvocation* invocation,
                                     gpointer user_data) {
  Impl* impl = static_cast<Impl*>(user_data);
  if (std::strcmp(method_name, "Activate") == 0) {
    if (impl->activation_handler) {
      try {
        impl->activation_handler();
      } catch (...) {
      }
    }
  }
  // SecondaryActivate and Scroll have no first-party behaviour yet; they are
  // accepted so watchers never see an error for a standard method.
  g_dbus_method_invocation_return_value(invocation, nullptr);
}

GVariant* TrayIcon::Impl::menu_get_property(GDBusConnection*, gchar const*,
                                            gchar const*, gchar const*,
                                            gchar const* property_name,
                                            GError**, gpointer) {
  std::string const name = property_name;
  if (name == "Version") return g_variant_new_uint32(3);
  if (name == "TextDirection") return g_variant_new_string("ltr");
  if (name == "Status") return g_variant_new_string("normal");
  if (name == "IconThemePath") {
    GVariantBuilder path_array;
    g_variant_builder_init(&path_array, G_VARIANT_TYPE("as"));
    return g_variant_builder_end(&path_array);
  }
  return nullptr;
}

void TrayIcon::Impl::menu_method_call(GDBusConnection*, gchar const*,
                                      gchar const*, gchar const*,
                                      gchar const* method_name,
                                      GVariant* parameters,
                                      GDBusMethodInvocation* invocation,
                                      gpointer user_data) {
  Impl* impl = static_cast<Impl*>(user_data);

  if (std::strcmp(method_name, "GetLayout") == 0) {
    GVariant* parent_value = g_variant_get_child_value(parameters, 0);
    gint const parent_id = g_variant_get_int32(parent_value);
    g_variant_unref(parent_value);
    std::lock_guard<std::mutex> guard(impl->mutex);
    if (parent_id < 0 || parent_id > static_cast<gint>(impl->items.size())) {
      g_dbus_method_invocation_return_dbus_error(
          invocation, "com.canonical.dbusmenu.Error.NoItem", "no such item");
      return;
    }
    g_dbus_method_invocation_return_value(
        invocation,
        g_variant_new("(u@(ia{sv}av))", impl->revision,
                      impl->layout_node(parent_id)));
    return;
  }

  if (std::strcmp(method_name, "GetGroupProperties") == 0) {
    GVariant* ids_variant = g_variant_get_child_value(parameters, 0);
    std::vector<gint> requested;
    GVariantIter id_iterator;
    g_variant_iter_init(&id_iterator, ids_variant);
    gint id = 0;
    while (g_variant_iter_loop(&id_iterator, "i", &id)) requested.push_back(id);
    g_variant_unref(ids_variant);

    GVariantBuilder result;
    g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
    std::lock_guard<std::mutex> guard(impl->mutex);
    if (requested.empty()) {
      for (gint item_id = 1; item_id <= static_cast<gint>(impl->items.size());
           ++item_id) {
        g_variant_builder_add(&result, "(i@a{sv})", item_id,
                              impl->item_properties(item_id));
      }
    } else {
      for (gint item_id : requested) {
        if (item_id < 1 || item_id > static_cast<gint>(impl->items.size()))
          continue;
        g_variant_builder_add(&result, "(i@a{sv})", item_id,
                              impl->item_properties(item_id));
      }
    }
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(a(ia{sv}))", &result));
    return;
  }

  if (std::strcmp(method_name, "GetProperty") == 0) {
    GVariant* id_value = g_variant_get_child_value(parameters, 0);
    GVariant* name_value = g_variant_get_child_value(parameters, 1);
    gint const item_id = g_variant_get_int32(id_value);
    gchar const* property =
        g_variant_get_string(name_value, nullptr);
    GVariant* value = nullptr;
    {
      std::lock_guard<std::mutex> guard(impl->mutex);
      if (item_id >= 1 && item_id <= static_cast<gint>(impl->items.size())) {
        GVariant* all = impl->item_properties(item_id);
        GVariant* found = g_variant_lookup_value(all, property, nullptr);
        if (found) value = found;
        g_variant_unref(all);
      }
    }
    g_variant_unref(id_value);
    g_variant_unref(name_value);
    if (!value) value = g_variant_new_string("");
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(v)", value));
    return;
  }

  if (std::strcmp(method_name, "Event") == 0) {
    GVariant* id_value = g_variant_get_child_value(parameters, 0);
    GVariant* event_value = g_variant_get_child_value(parameters, 1);
    impl->dispatch_event(g_variant_get_int32(id_value),
                         g_variant_get_string(event_value, nullptr));
    g_variant_unref(id_value);
    g_variant_unref(event_value);
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (std::strcmp(method_name, "EventGroup") == 0) {
    GVariant* events = g_variant_get_child_value(parameters, 0);
    GVariantIter event_iterator;
    g_variant_iter_init(&event_iterator, events);
    gint item_id = 0;
    gchar* event_id = nullptr;
    while (g_variant_iter_loop(&event_iterator, "(isvu)", &item_id, &event_id,
                               nullptr, nullptr)) {
      impl->dispatch_event(item_id, event_id);
    }
    g_variant_unref(events);
    GVariantBuilder errors;
    g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(ai)", &errors));
    return;
  }

  if (std::strcmp(method_name, "AboutToShow") == 0) {
    // Layout changes are announced through LayoutUpdated, so there is never
    // a pending update to reveal here.
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(b)", FALSE));
    return;
  }

  if (std::strcmp(method_name, "AboutToShowGroup") == 0) {
    GVariantBuilder updates;
    g_variant_builder_init(&updates, G_VARIANT_TYPE("ai"));
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(ai)", &updates));
    return;
  }

  g_dbus_method_invocation_return_dbus_error(
      invocation, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
}

void TrayIcon::Impl::watcher_owner_changed(GDBusConnection*, gchar const*,
                                           gchar const*, gchar const*,
                                           gchar const*, GVariant* parameters,
                                           gpointer user_data) {
  gchar* new_owner = nullptr;
  g_variant_get(parameters, "(sss)", nullptr, nullptr, &new_owner);
  gboolean const appeared = new_owner && *new_owner != '\0';
  g_free(new_owner);
  if (!appeared) return;
  Impl* impl = static_cast<Impl*>(user_data);
  try {
    impl->register_with_watcher();
  } catch (...) {
    // The watcher may vanish again before answering; the next appearance
    // retries. A missing icon is visible on the desktop, not fatal here.
  }
}

bool TrayIcon::available() {
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
      "org.freedesktop.DBus", "GetNameOwner",
      g_variant_new("(s)", kStatusNotifierWatcherName), G_VARIANT_TYPE("(s)"),
      G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  if (!owner) {
    if (error) g_error_free(error);
    available_state = 0;
    return false;
  }
  g_variant_unref(owner);
  available_state = 1;
  return true;
}

TrayIcon::TrayIcon(std::string const& application_id,
                   std::string const& title, std::string const& icon_name)
    : impl_(std::make_unique<Impl>()) {
  GDBusConnection* bus = session_bus();
  if (!bus)
    throw std::runtime_error(
        "tray is unavailable: no D-Bus session bus is reachable");
  if (!available())
    throw std::runtime_error(
        "tray is unavailable: no StatusNotifierItem watcher is running");

  impl_->bus = bus;
  impl_->id = application_id;
  impl_->title = title;
  impl_->icon_name = icon_name;

  // Object paths must be unique per instance; a process may host several
  // icons (one per window, for example).
  static std::atomic<int> instance_counter{0};
  std::string const element = sanitize_path_element(application_id);
  impl_->object_path = "/org/rivet/tray/" +
                       (element.empty() ? std::string("app") : element) + "_" +
                       std::to_string(instance_counter.fetch_add(1));
  impl_->menu_path = impl_->object_path + "/menu";

  GError* error = nullptr;
  impl_->sni_registration = g_dbus_connection_register_object(
      bus, impl_->object_path.c_str(),
      status_notifier_item_info()->interfaces[0], &Impl::sni_vtable,
      impl_.get(), nullptr, &error);
  if (!impl_->sni_registration) {
    std::string message = error_message("tray object registration failed", error);
    throw std::runtime_error(message);
  }
  impl_->menu_registration = g_dbus_connection_register_object(
      bus, impl_->menu_path.c_str(), dbus_menu_info()->interfaces[0],
      &Impl::menu_vtable, impl_.get(), nullptr, &error);
  if (!impl_->menu_registration) {
    std::string message = error_message("tray menu registration failed", error);
    throw std::runtime_error(message);
  }

  // Watch for the watcher: GNOME Shell restarts and extension reloads
  // replace the StatusNotifierItem watcher without touching this process.
  impl_->watcher_subscription = g_dbus_connection_signal_subscribe(
      bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
      "/org/freedesktop/DBus", kStatusNotifierWatcherName,
      G_DBUS_SIGNAL_FLAGS_NONE, &Impl::watcher_owner_changed, impl_.get(),
      nullptr);

  impl_->register_with_watcher();
}

TrayIcon::~TrayIcon() = default;

void TrayIcon::set_icon(std::string const& icon_name) {
  impl_->icon_name = icon_name;
  impl_->emit_sni_signal("NewIcon");
}

void TrayIcon::set_tooltip(std::string const& title, std::string const& body) {
  impl_->tooltip_title = title;
  impl_->tooltip_body = body;
  impl_->emit_sni_signal("NewToolTip");
}

void TrayIcon::set_menu(std::vector<TrayMenuItem> items) {
  std::uint32_t updated_revision = 0;
  {
    std::lock_guard<std::mutex> guard(impl_->mutex);
    impl_->items = std::move(items);
    updated_revision = ++impl_->revision;
  }
  g_dbus_connection_emit_signal(
      impl_->bus, nullptr, impl_->menu_path.c_str(), "com.canonical.dbusmenu",
      "LayoutUpdated", g_variant_new("(ui)", updated_revision, 0), nullptr);
}

void TrayIcon::set_activation_handler(std::function<void()> handler) {
  impl_->activation_handler = std::move(handler);
}


void InstallCrashHook(CrashCallback callback,
                      std::string const& restart_arguments) {
  if (crash_log_fd >= 0)
    throw std::runtime_error("crash hook is already installed");

  std::string directory = xdg_state_home() + "/rivet";
  ::mkdir(xdg_state_home().c_str(), 0700);
  ::mkdir(directory.c_str(), 0700);
  std::string path = directory + "/crash.log";
  int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (fd < 0)
    throw std::runtime_error(std::string("crash hook could not open ") + path +
                             ": " + std::strerror(errno));

  crash_log_fd = fd;
  crash_note_suffix =
      restart_arguments.empty() ? std::string() : " restart=" + restart_arguments;
  crash_user_callback = callback;

  int const watched_signals[] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};
  struct sigaction action;
  std::memset(&action, 0, sizeof(action));
  action.sa_handler = rivet_crash_signal_handler;
  sigemptyset(&action.sa_mask);
  for (int signal_number : watched_signals) {
    if (sigaction(signal_number, &action, nullptr) != 0) {
      int saved = errno;
      crash_log_fd = -1;
      crash_user_callback = nullptr;
      ::close(fd);
      throw std::runtime_error(std::string("crash hook installation failed: ") +
                               std::strerror(saved));
    }
  }
}

}  // namespace rivet::system
