#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <future>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

#include <gio/gio.h>

#include "system_services.hpp"

namespace {

constexpr char const* kPortalName = "org.freedesktop.portal.Desktop";
constexpr char const* kPortalPath = "/org/freedesktop/portal/desktop";
constexpr char const* kShortcutInterface =
    "org.freedesktop.portal.GlobalShortcuts";
constexpr char const* kRequestInterface = "org.freedesktop.portal.Request";
constexpr char const* kSessionPath =
    "/org/freedesktop/portal/desktop/session/rivet_test/session";

void require(bool condition, char const* message) {
  if (!condition) throw std::runtime_error(message);
}

std::string sender_path_element(char const* sender) {
  std::string element(sender && sender[0] == ':' ? sender + 1 : sender);
  for (char& character : element) {
    bool const allowed =
        (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') || character == '_';
    if (!allowed) character = '_';
  }
  return element;
}

std::string option_string(GVariant* options, char const* name) {
  char const* value = nullptr;
  if (!g_variant_lookup(options, name, "&s", &value) || !value) return {};
  return value;
}

class MockGlobalShortcutsPortal final {
 public:
  MockGlobalShortcutsPortal() {
    std::promise<std::string> started;
    auto ready = started.get_future();
    thread_ = std::thread(
        [this, started = std::move(started)]() mutable {
          serve(std::move(started));
        });
    std::string const error = ready.get();
    if (!error.empty()) {
      thread_.join();
      throw std::runtime_error(error);
    }
  }

  ~MockGlobalShortcutsPortal() {
    g_main_context_invoke(
        context_,
        [](gpointer data) -> gboolean {
          g_main_loop_quit(static_cast<GMainLoop*>(data));
          return G_SOURCE_REMOVE;
        },
        loop_);
    thread_.join();
  }

  MockGlobalShortcutsPortal(MockGlobalShortcutsPortal const&) = delete;
  MockGlobalShortcutsPortal& operator=(MockGlobalShortcutsPortal const&) =
      delete;

 private:
  static void return_error(GDBusMethodInvocation* invocation,
                           char const* message) {
    g_dbus_method_invocation_return_dbus_error(
        invocation, "org.freedesktop.portal.Error.InvalidArgument", message);
  }

  static void emit_response(GDBusConnection* connection, char const* sender,
                            std::string const& path, GVariant* results) {
    GError* error = nullptr;
    g_dbus_connection_emit_signal(
        connection, sender, path.c_str(), kRequestInterface, "Response",
        g_variant_new("(u@a{sv})", 0U, results), &error);
    if (error) {
      std::cerr << "mock portal response failed: " << error->message << "\n";
      g_error_free(error);
    }
  }

  static void method_called(GDBusConnection* connection, char const* sender,
                            char const*, char const* interface_name,
                            char const* method_name, GVariant* parameters,
                            GDBusMethodInvocation* invocation, gpointer) {
    if (std::string(interface_name) == "org.freedesktop.portal.Session" &&
        std::string(method_name) == "Close") {
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (std::string(interface_name) != kShortcutInterface) {
      return_error(invocation, "unexpected interface");
      return;
    }

    if (std::string(method_name) == "CreateSession") {
      GVariant* options = nullptr;
      g_variant_get(parameters, "(@a{sv})", &options);
      std::string const token = option_string(options, "handle_token");
      std::string const session_token =
          option_string(options, "session_handle_token");
      g_variant_unref(options);
      if (token.empty() || session_token.empty()) {
        return_error(invocation, "missing request or session token");
        return;
      }
      std::string const request_path =
          "/org/freedesktop/portal/desktop/request/" +
          sender_path_element(sender) + "/" + token;
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(o)", request_path.c_str()));

      GVariantBuilder results;
      g_variant_builder_init(&results, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&results, "{sv}", "session_handle",
                            g_variant_new_string(kSessionPath));
      emit_response(connection, sender, request_path,
                    g_variant_builder_end(&results));
      return;
    }

    if (std::string(method_name) == "BindShortcuts") {
      char const* session = nullptr;
      GVariant* shortcuts = nullptr;
      char const* parent_window = nullptr;
      GVariant* options = nullptr;
      g_variant_get(parameters, "(&o@a(sa{sv})&s@a{sv})", &session,
                    &shortcuts, &parent_window, &options);
      std::string const token = option_string(options, "handle_token");
      g_variant_unref(options);
      if (!session || std::string(session) != kSessionPath || token.empty()) {
        g_variant_unref(shortcuts);
        return_error(invocation, "invalid session or request token");
        return;
      }

      GVariantIter iterator;
      g_variant_iter_init(&iterator, shortcuts);
      char const* shortcut_id = nullptr;
      GVariant* properties = nullptr;
      bool const has_shortcut = g_variant_iter_next(
          &iterator, "(&s@a{sv})", &shortcut_id, &properties);
      std::string id = shortcut_id ? shortcut_id : "";
      std::string description =
          has_shortcut ? option_string(properties, "description") : "";
      if (properties) g_variant_unref(properties);
      g_variant_unref(shortcuts);
      if (!has_shortcut || id.empty() || description.empty()) {
        return_error(invocation, "expected one described shortcut");
        return;
      }

      std::string const request_path =
          "/org/freedesktop/portal/desktop/request/" +
          sender_path_element(sender) + "/" + token;
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(o)", request_path.c_str()));

      GVariantBuilder binding_properties;
      g_variant_builder_init(&binding_properties, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&binding_properties, "{sv}", "description",
                            g_variant_new_string(description.c_str()));
      g_variant_builder_add(&binding_properties, "{sv}",
                            "trigger_description",
                            g_variant_new_string("Alt+Space"));
      GVariantBuilder bindings;
      g_variant_builder_init(&bindings, G_VARIANT_TYPE("a(sa{sv})"));
      g_variant_builder_add(&bindings, "(s@a{sv})", id.c_str(),
                            g_variant_builder_end(&binding_properties));
      GVariantBuilder results;
      g_variant_builder_init(&results, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&results, "{sv}", "shortcuts",
                            g_variant_builder_end(&bindings));
      emit_response(connection, sender, request_path,
                    g_variant_builder_end(&results));

      GVariantBuilder activation_options;
      g_variant_builder_init(&activation_options, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&activation_options, "{sv}", "activation_token",
                            g_variant_new_string("rivet-test-token"));
      GError* error = nullptr;
      g_dbus_connection_emit_signal(
          connection, sender, kPortalPath, kShortcutInterface, "Activated",
          g_variant_new("(ost@a{sv})", kSessionPath, id.c_str(),
                        static_cast<guint64>(42),
                        g_variant_builder_end(&activation_options)),
          &error);
      if (error) {
        std::cerr << "mock activation failed: " << error->message << "\n";
        g_error_free(error);
      }
      return;
    }

    return_error(invocation, "unexpected method");
  }

  static GVariant* property_read(GDBusConnection*, char const*, char const*,
                                 char const* interface_name,
                                 char const* property_name, GError**,
                                 gpointer) {
    if (std::string(interface_name) == kShortcutInterface &&
        std::string(property_name) == "version") {
      return g_variant_new_uint32(2);
    }
    return nullptr;
  }

  void serve(std::promise<std::string> started) noexcept {
    GDBusConnection* connection = nullptr;
    GDBusNodeInfo* portal_info = nullptr;
    GDBusNodeInfo* session_info = nullptr;
    guint portal_registration = 0;
    guint session_registration = 0;
    try {
      context_ = g_main_context_new();
      g_main_context_push_thread_default(context_);
      loop_ = g_main_loop_new(context_, FALSE);

      char const* address = std::getenv("DBUS_SESSION_BUS_ADDRESS");
      require(address && *address,
              "DBUS_SESSION_BUS_ADDRESS is missing; use dbus-run-session");
      GError* error = nullptr;
      connection = g_dbus_connection_new_for_address_sync(
          address,
          static_cast<GDBusConnectionFlags>(
              G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
              G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
          nullptr, nullptr, &error);
      if (!connection) {
        std::string message = "could not connect mock portal: ";
        message += error ? error->message : "unknown D-Bus error";
        if (error) g_error_free(error);
        throw std::runtime_error(message);
      }
      g_dbus_connection_set_exit_on_close(connection, FALSE);

      GVariant* name_reply = g_dbus_connection_call_sync(
          connection, "org.freedesktop.DBus", "/org/freedesktop/DBus",
          "org.freedesktop.DBus", "RequestName",
          g_variant_new("(su)", kPortalName, 0U), G_VARIANT_TYPE("(u)"),
          G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
      if (!name_reply) {
        std::string message = "could not own mock portal name: ";
        message += error ? error->message : "unknown D-Bus error";
        if (error) g_error_free(error);
        throw std::runtime_error(message);
      }
      guint32 name_result = 0;
      g_variant_get(name_reply, "(u)", &name_result);
      g_variant_unref(name_reply);
      require(name_result == 1 || name_result == 4,
              "mock portal name was already owned");

      static char const portal_xml[] = R"XML(
        <node>
          <interface name="org.freedesktop.portal.GlobalShortcuts">
            <method name="CreateSession">
              <arg type="a{sv}" direction="in"/>
              <arg type="o" direction="out"/>
            </method>
            <method name="BindShortcuts">
              <arg type="o" direction="in"/>
              <arg type="a(sa{sv})" direction="in"/>
              <arg type="s" direction="in"/>
              <arg type="a{sv}" direction="in"/>
              <arg type="o" direction="out"/>
            </method>
            <signal name="Activated">
              <arg type="o"/><arg type="s"/><arg type="t"/>
              <arg type="a{sv}"/>
            </signal>
            <property name="version" type="u" access="read"/>
          </interface>
        </node>)XML";
      static char const session_xml[] = R"XML(
        <node>
          <interface name="org.freedesktop.portal.Session">
            <method name="Close"/>
          </interface>
        </node>)XML";
      portal_info = g_dbus_node_info_new_for_xml(portal_xml, &error);
      require(portal_info != nullptr, "mock portal XML is invalid");
      session_info = g_dbus_node_info_new_for_xml(session_xml, &error);
      require(session_info != nullptr, "mock session XML is invalid");

      GDBusInterfaceVTable const vtable = {&method_called, &property_read,
                                           nullptr, {0}};
      portal_registration = g_dbus_connection_register_object(
          connection, kPortalPath, portal_info->interfaces[0], &vtable,
          nullptr, nullptr, &error);
      require(portal_registration != 0,
              "could not register mock shortcut portal");
      session_registration = g_dbus_connection_register_object(
          connection, kSessionPath, session_info->interfaces[0], &vtable,
          nullptr, nullptr, &error);
      require(session_registration != 0,
              "could not register mock shortcut session");

      started.set_value({});
      g_main_loop_run(loop_);
    } catch (std::exception const& exception) {
      started.set_value(exception.what());
    }

    if (connection && session_registration) {
      g_dbus_connection_unregister_object(connection, session_registration);
    }
    if (connection && portal_registration) {
      g_dbus_connection_unregister_object(connection, portal_registration);
    }
    if (portal_info) g_dbus_node_info_unref(portal_info);
    if (session_info) g_dbus_node_info_unref(session_info);
    if (connection) g_object_unref(connection);
    if (loop_) g_main_loop_unref(loop_);
    g_main_context_pop_thread_default(context_);
    if (context_) g_main_context_unref(context_);
  }

  std::thread thread_;
  GMainContext* context_ = nullptr;
  GMainLoop* loop_ = nullptr;
};

gboolean timeout_loop(gpointer data) {
  auto* state = static_cast<std::pair<GMainLoop*, bool*>*>(data);
  *state->second = true;
  g_main_loop_quit(state->first);
  return G_SOURCE_REMOVE;
}

}  // namespace

int main() {
  try {
    MockGlobalShortcutsPortal portal;
    auto const support = rivet::system::GlobalShortcuts::support();
    require(support.available, "mock GlobalShortcuts portal was not detected");
    require(support.portal_version == 2,
            "mock GlobalShortcuts portal version was not preserved");

    bool bound = false;
    bool activated = false;
    bool timed_out = false;
    std::string callback_error;
    GMainLoop* loop = g_main_loop_new(nullptr, FALSE);
    std::pair<GMainLoop*, bool*> timeout_state{loop, &timed_out};
    guint const timeout = g_timeout_add_seconds(5, &timeout_loop,
                                                &timeout_state);
    {
      rivet::system::GlobalShortcuts shortcuts;
      shortcuts.set_activation_handler(
          [&](std::string const& id, std::uint64_t timestamp,
              std::string const& token) {
            if (id != "toggle") {
              callback_error = "activation returned the wrong id";
            } else if (timestamp != 42) {
              callback_error = "activation returned the wrong timestamp";
            } else if (token != "rivet-test-token") {
              callback_error = "activation token was not preserved";
            }
            activated = true;
            if (bound || !callback_error.empty()) g_main_loop_quit(loop);
          });
      shortcuts.bind(
          {{"toggle", "Show or hide the window", "ALT+space"}}, {},
          [&](rivet::system::GlobalShortcutBindResult result) {
            if (result.status !=
                rivet::system::GlobalShortcutBindStatus::bound) {
              callback_error = "portal binding did not succeed";
            } else if (result.bindings.size() != 1) {
              callback_error =
                  "portal did not return exactly one binding";
            } else if (result.bindings[0].id != "toggle") {
              callback_error = "portal binding returned the wrong id";
            } else if (result.bindings[0].trigger_description != "Alt+Space") {
              callback_error =
                  "portal trigger description was not preserved";
            }
            bound = true;
            if (activated || !callback_error.empty()) g_main_loop_quit(loop);
          });
      g_main_loop_run(loop);
    }
    if (!timed_out) g_source_remove(timeout);
    g_main_loop_unref(loop);
    require(!timed_out, "timed out waiting for portal callbacks");
    require(callback_error.empty(), callback_error.c_str());
    require(bound && activated,
            "portal binding and activation did not both complete");
    std::cout << "Rivet GlobalShortcuts portal checks passed\n";
    return 0;
  } catch (std::exception const& error) {
    std::cerr << "Rivet GlobalShortcuts portal failure: " << error.what()
              << "\n";
    return 1;
  }
}
