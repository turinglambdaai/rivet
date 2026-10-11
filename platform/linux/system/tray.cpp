#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <cctype>
#include <mutex>
#include <stdexcept>

#include <gio/gio.h>
#include <glib.h>

namespace rivet::system {

using detail::error_message;
using detail::session_bus;

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




}  // namespace rivet::system
