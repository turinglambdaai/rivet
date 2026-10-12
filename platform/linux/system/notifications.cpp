#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <mutex>
#include <stdexcept>
#include <unordered_map>

#include <gio/gio.h>
#include <glib.h>

namespace rivet::system {
namespace {

using detail::error_message;
using detail::session_bus;

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


}  // namespace

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



}  // namespace rivet::system
