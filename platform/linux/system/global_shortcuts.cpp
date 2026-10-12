#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <atomic>
#include <memory>
#include <stdexcept>
#include <unordered_set>
#include <utility>

#include <gio/gio.h>

namespace rivet::system {
namespace {

using detail::session_bus;

constexpr char const* kPortalName = "org.freedesktop.portal.Desktop";
constexpr char const* kPortalPath = "/org/freedesktop/portal/desktop";
constexpr char const* kGlobalShortcutsInterface =
    "org.freedesktop.portal.GlobalShortcuts";
constexpr char const* kRequestInterface = "org.freedesktop.portal.Request";
constexpr char const* kSessionInterface = "org.freedesktop.portal.Session";

std::string take_error_message(char const* prefix, GError* error) {
  std::string message = prefix;
  if (error) {
    message += ": ";
    message += error->message;
    g_error_free(error);
  }
  return message;
}

std::string sender_path_element(GDBusConnection* bus) {
  char const* unique_name = g_dbus_connection_get_unique_name(bus);
  if (!unique_name || !*unique_name) {
    throw std::runtime_error("the D-Bus session connection has no unique name");
  }
  std::string element(unique_name[0] == ':' ? unique_name + 1 : unique_name);
  for (char& character : element) {
    bool const allowed =
        (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') || character == '_';
    if (!allowed) character = '_';
  }
  return element;
}

std::string next_token() {
  static std::atomic<std::uint64_t> counter{1};
  return "rivet" + std::to_string(counter.fetch_add(1));
}

std::string request_path(GDBusConnection* bus, std::string const& token) {
  return "/org/freedesktop/portal/desktop/request/" +
         sender_path_element(bus) + "/" + token;
}

bool contains_nul(std::string const& value) {
  return value.find('\0') != std::string::npos;
}

GlobalShortcutSupport parse_support_reply(GVariant* reply) {
  GVariant* boxed = nullptr;
  g_variant_get(reply, "(@v)", &boxed);
  GVariant* value = g_variant_get_variant(boxed);
  if (!g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) {
    g_variant_unref(value);
    g_variant_unref(boxed);
    return {false, 0,
            "GlobalShortcuts portal returned a non-integer version"};
  }
  std::uint32_t const version = g_variant_get_uint32(value);
  g_variant_unref(value);
  g_variant_unref(boxed);
  if (version == 0) {
    return {false, 0, "GlobalShortcuts portal reported version 0"};
  }
  return {true, version, {}};
}

}  // namespace

struct GlobalShortcuts::Impl final
    : std::enable_shared_from_this<GlobalShortcuts::Impl> {
  enum class CallStage { detect_support, create_session, bind_shortcuts };

  struct PendingCall final {
    std::shared_ptr<Impl> impl;
    CallStage stage;
  };

  GDBusConnection* bus = nullptr;
  GCancellable* cancellable = nullptr;
  guint create_subscription = 0;
  guint bind_subscription = 0;
  guint activation_subscription = 0;
  bool bind_started = false;
  bool create_finished = false;
  bool bind_finished = false;
  bool closing = false;
  std::string session_handle;
  std::vector<GlobalShortcutSpec> shortcuts;
  std::string parent_window;
  BindHandler completion;
  ActivationHandler activation_handler;

  explicit Impl(GDBusConnection* connection)
      : bus(connection), cancellable(g_cancellable_new()) {}

  ~Impl() {
    if (cancellable) g_object_unref(cancellable);
  }

  static PendingCall* pending(std::shared_ptr<Impl> impl, CallStage stage) {
    return new PendingCall{std::move(impl), stage};
  }

  void unsubscribe(guint& subscription) {
    if (bus && subscription != 0) {
      g_dbus_connection_signal_unsubscribe(bus, subscription);
      subscription = 0;
    }
  }

  void close() {
    if (closing) return;
    closing = true;
    g_cancellable_cancel(cancellable);
    unsubscribe(create_subscription);
    unsubscribe(bind_subscription);
    unsubscribe(activation_subscription);
    if (bus && !session_handle.empty()) {
      g_dbus_connection_call(bus, kPortalName, session_handle.c_str(),
                             kSessionInterface, "Close", nullptr, nullptr,
                             G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr,
                             nullptr);
      session_handle.clear();
    }
    completion = nullptr;
    activation_handler = nullptr;
  }

  void finish(GlobalShortcutBindResult result) {
    if (closing || !completion) return;
    BindHandler callback = std::move(completion);
    if (result.status != GlobalShortcutBindStatus::bound) {
      unsubscribe(activation_subscription);
      if (bus && !session_handle.empty()) {
        g_dbus_connection_call(bus, kPortalName, session_handle.c_str(),
                               kSessionInterface, "Close", nullptr, nullptr,
                               G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr,
                               nullptr);
        session_handle.clear();
      }
    }
    try {
      callback(std::move(result));
    } catch (...) {
      // A host callback must not unwind through GLib's C signal dispatcher.
    }
  }

  void finish_response(std::uint32_t response, char const* operation) {
    if (response == 1) {
      finish({GlobalShortcutBindStatus::cancelled, {},
              std::string(operation) + " was cancelled by the user"});
    } else {
      finish({GlobalShortcutBindStatus::failed, {},
              std::string(operation) + " failed in the desktop portal"});
    }
  }

  void method_failed(CallStage stage, GError* error) {
    std::string message = take_error_message(
        stage == CallStage::create_session
            ? "global shortcut session creation failed"
            : "global shortcut binding failed",
        error);
    if (closing || (stage == CallStage::create_session && create_finished) ||
        (stage == CallStage::bind_shortcuts && bind_finished)) {
      return;
    }
    if (stage == CallStage::create_session) {
      unsubscribe(create_subscription);
    } else {
      unsubscribe(bind_subscription);
    }
    finish({GlobalShortcutBindStatus::failed, {}, std::move(message)});
  }

  static void call_returned(GObject* source, GAsyncResult* result,
                            gpointer data) {
    std::unique_ptr<PendingCall> call(static_cast<PendingCall*>(data));
    GError* error = nullptr;
    GVariant* reply = g_dbus_connection_call_finish(
        G_DBUS_CONNECTION(source), result, &error);
    if (!reply) {
      if (call->stage == CallStage::detect_support) {
        call->impl->finish(
            {GlobalShortcutBindStatus::unavailable, {},
             take_error_message("GlobalShortcuts portal is unavailable",
                                error)});
        return;
      }
      call->impl->method_failed(call->stage, error);
      return;
    }
    if (call->stage == CallStage::detect_support) {
      GlobalShortcutSupport const detected = parse_support_reply(reply);
      g_variant_unref(reply);
      if (!detected.available) {
        call->impl->finish({GlobalShortcutBindStatus::unavailable, {},
                            detected.reason});
      } else if (!call->impl->closing) {
        call->impl->start_create_session();
      }
      return;
    }
    g_variant_unref(reply);
  }

  void start_support_check() {
    if (!bus) {
      finish({GlobalShortcutBindStatus::unavailable, {},
              "no D-Bus session bus is reachable"});
      return;
    }
    g_dbus_connection_call(
        bus, kPortalName, kPortalPath, "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", kGlobalShortcutsInterface, "version"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1000, cancellable,
        &Impl::call_returned,
        pending(shared_from_this(), CallStage::detect_support));
  }

  void start_create_session() {
    std::string const handle_token = next_token();
    std::string const session_token = next_token();
    std::string const path = request_path(bus, handle_token);
    create_subscription = g_dbus_connection_signal_subscribe(
        bus, kPortalName, kRequestInterface, "Response", path.c_str(), nullptr,
        G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, &Impl::session_created, this,
        nullptr);

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token",
                          g_variant_new_string(handle_token.c_str()));
    g_variant_builder_add(&options, "{sv}", "session_handle_token",
                          g_variant_new_string(session_token.c_str()));
    g_dbus_connection_call(
        bus, kPortalName, kPortalPath, kGlobalShortcutsInterface,
        "CreateSession", g_variant_new("(a{sv})", &options),
        G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, cancellable,
        &Impl::call_returned,
        pending(shared_from_this(), CallStage::create_session));
  }

  static void session_created(GDBusConnection*, gchar const*, gchar const*,
                              gchar const*, gchar const*, GVariant* parameters,
                              gpointer data) {
    Impl* impl = static_cast<Impl*>(data);
    if (impl->closing) return;
    impl->create_finished = true;
    impl->unsubscribe(impl->create_subscription);

    guint32 response = 2;
    GVariant* results = nullptr;
    g_variant_get(parameters, "(u@a{sv})", &response, &results);
    if (response != 0) {
      g_variant_unref(results);
      impl->finish_response(response, "global shortcut session creation");
      return;
    }
    gchar const* handle = nullptr;
    bool const found =
        g_variant_lookup(results, "session_handle", "&s", &handle) && handle;
    if (found) impl->session_handle = handle;
    g_variant_unref(results);
    if (!found || impl->session_handle.empty()) {
      impl->finish({GlobalShortcutBindStatus::failed, {},
                    "global shortcut portal returned no session handle"});
      return;
    }

    impl->activation_subscription = g_dbus_connection_signal_subscribe(
        impl->bus, kPortalName, kGlobalShortcutsInterface, "Activated",
        kPortalPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        &Impl::shortcut_activated, impl, nullptr);
    impl->start_bind_shortcuts();
  }

  void start_bind_shortcuts() {
    std::string const handle_token = next_token();
    std::string const path = request_path(bus, handle_token);
    bind_subscription = g_dbus_connection_signal_subscribe(
        bus, kPortalName, kRequestInterface, "Response", path.c_str(), nullptr,
        G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, &Impl::shortcuts_bound, this,
        nullptr);

    GVariantBuilder shortcut_values;
    g_variant_builder_init(&shortcut_values, G_VARIANT_TYPE("a(sa{sv})"));
    for (GlobalShortcutSpec const& shortcut : shortcuts) {
      GVariantBuilder properties;
      g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&properties, "{sv}", "description",
                            g_variant_new_string(shortcut.description.c_str()));
      if (!shortcut.preferred_trigger.empty()) {
        g_variant_builder_add(
            &properties, "{sv}", "preferred_trigger",
            g_variant_new_string(shortcut.preferred_trigger.c_str()));
      }
      g_variant_builder_add(&shortcut_values, "(s@a{sv})",
                            shortcut.id.c_str(),
                            g_variant_builder_end(&properties));
    }

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token",
                          g_variant_new_string(handle_token.c_str()));
    g_dbus_connection_call(
        bus, kPortalName, kPortalPath, kGlobalShortcutsInterface,
        "BindShortcuts",
        g_variant_new("(o@a(sa{sv})s@a{sv})", session_handle.c_str(),
                      g_variant_builder_end(&shortcut_values),
                      parent_window.c_str(), g_variant_builder_end(&options)),
        G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, cancellable,
        &Impl::call_returned,
        pending(shared_from_this(), CallStage::bind_shortcuts));
  }

  static void shortcuts_bound(GDBusConnection*, gchar const*, gchar const*,
                              gchar const*, gchar const*, GVariant* parameters,
                              gpointer data) {
    Impl* impl = static_cast<Impl*>(data);
    if (impl->closing) return;
    impl->bind_finished = true;
    impl->unsubscribe(impl->bind_subscription);

    guint32 response = 2;
    GVariant* results = nullptr;
    g_variant_get(parameters, "(u@a{sv})", &response, &results);
    if (response != 0) {
      g_variant_unref(results);
      impl->finish_response(response, "global shortcut binding");
      return;
    }

    GVariant* values = g_variant_lookup_value(
        results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
    g_variant_unref(results);
    if (!values) {
      impl->finish({GlobalShortcutBindStatus::failed, {},
                    "global shortcut portal returned no binding list"});
      return;
    }

    std::vector<GlobalShortcutBinding> bindings;
    GVariantIter iterator;
    g_variant_iter_init(&iterator, values);
    gchar const* id = nullptr;
    GVariant* properties = nullptr;
    while (g_variant_iter_next(&iterator, "(&s@a{sv})", &id, &properties)) {
      gchar const* description = "";
      gchar const* trigger = "";
      g_variant_lookup(properties, "description", "&s", &description);
      g_variant_lookup(properties, "trigger_description", "&s", &trigger);
      bindings.push_back({id ? id : "", description ? description : "",
                          trigger ? trigger : ""});
      g_variant_unref(properties);
    }
    g_variant_unref(values);
    impl->finish({GlobalShortcutBindStatus::bound, std::move(bindings), {}});
  }

  static void shortcut_activated(GDBusConnection*, gchar const*, gchar const*,
                                 gchar const*, gchar const*,
                                 GVariant* parameters, gpointer data) {
    Impl* impl = static_cast<Impl*>(data);
    if (impl->closing || !impl->activation_handler) return;
    gchar const* session = nullptr;
    gchar const* shortcut_id = nullptr;
    guint64 timestamp = 0;
    GVariant* options = nullptr;
    g_variant_get(parameters, "(&o&st@a{sv})", &session, &shortcut_id,
                  &timestamp, &options);
    if (!session || impl->session_handle != session) {
      g_variant_unref(options);
      return;
    }
    gchar const* token = "";
    g_variant_lookup(options, "activation_token", "&s", &token);
    try {
      impl->activation_handler(shortcut_id ? shortcut_id : "", timestamp,
                               token ? token : "");
    } catch (...) {
      // A host callback must not unwind through GLib's C signal dispatcher.
    }
    g_variant_unref(options);
  }
};

GlobalShortcutSupport GlobalShortcuts::support() {
  GDBusConnection* bus = session_bus();
  if (!bus) {
    return {false, 0, "no D-Bus session bus is reachable"};
  }

  GError* error = nullptr;
  GVariant* reply = g_dbus_connection_call_sync(
      bus, kPortalName, kPortalPath, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", kGlobalShortcutsInterface, "version"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  if (!reply) {
    return {false, 0,
            take_error_message("GlobalShortcuts portal is unavailable", error)};
  }
  GlobalShortcutSupport const detected = parse_support_reply(reply);
  g_variant_unref(reply);
  return detected;
}

GlobalShortcuts::GlobalShortcuts()
    : impl_(std::make_shared<Impl>(session_bus())) {}

GlobalShortcuts::~GlobalShortcuts() {
  if (impl_) impl_->close();
}

void GlobalShortcuts::bind(std::vector<GlobalShortcutSpec> shortcuts,
                           std::string parent_window,
                           BindHandler completion) {
  if (!completion) {
    throw std::invalid_argument("global shortcut completion must not be empty");
  }
  if (impl_->bind_started) {
    throw std::logic_error(
        "a GlobalShortcuts object can bind shortcuts only once");
  }
  if (shortcuts.empty()) {
    throw std::invalid_argument("at least one global shortcut is required");
  }
  std::unordered_set<std::string> ids;
  for (GlobalShortcutSpec const& shortcut : shortcuts) {
    if (shortcut.id.empty() || contains_nul(shortcut.id)) {
      throw std::invalid_argument(
          "global shortcut ids must be non-empty D-Bus strings");
    }
    if (!ids.insert(shortcut.id).second) {
      throw std::invalid_argument("global shortcut ids must be unique");
    }
    if (shortcut.description.empty() || contains_nul(shortcut.description) ||
        contains_nul(shortcut.preferred_trigger)) {
      throw std::invalid_argument(
          "global shortcut descriptions must be non-empty D-Bus strings");
    }
  }
  if (contains_nul(parent_window)) {
    throw std::invalid_argument(
        "global shortcut parent window must be a D-Bus string");
  }

  impl_->bind_started = true;
  impl_->shortcuts = std::move(shortcuts);
  impl_->parent_window = std::move(parent_window);
  impl_->completion = std::move(completion);

  impl_->start_support_check();
}

void GlobalShortcuts::set_activation_handler(ActivationHandler handler) {
  impl_->activation_handler = std::move(handler);
}

}  // namespace rivet::system
