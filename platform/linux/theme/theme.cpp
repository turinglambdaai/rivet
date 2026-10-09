#include "theme.hpp"

#include <gtk/gtk.h>

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <string>

namespace rivet::linux_ui {
namespace {

bool ends_with_dark(std::string const& name) {
  constexpr char suffix[] = "-dark";
  constexpr std::size_t suffix_size = sizeof(suffix) - 1;
  if (name.size() < suffix_size) return false;
  auto const begin = name.end() - static_cast<std::ptrdiff_t>(suffix_size);
  return std::equal(begin, name.end(), suffix, [](char left, char right) {
    return std::tolower(static_cast<unsigned char>(left)) == right;
  });
}

std::string desktop_color_scheme() {
  GSettingsSchemaSource* source = g_settings_schema_source_get_default();
  if (source == nullptr) return {};
  GSettingsSchema* schema = g_settings_schema_source_lookup(
      source, "org.gnome.desktop.interface", TRUE);
  if (schema == nullptr) return {};

  std::string result;
  if (g_settings_schema_has_key(schema, "color-scheme")) {
    GSettings* settings = g_settings_new_full(schema, nullptr, nullptr);
    gchar* value = g_settings_get_string(settings, "color-scheme");
    if (value != nullptr) result = value;
    g_free(value);
    g_object_unref(settings);
  }
  g_settings_schema_unref(schema);
  return result;
}

}  // namespace

ThemeSelection ResolveTheme(std::string current_theme_name,
                            std::string desktop_scheme,
                            bool gtk_prefers_dark,
                            ThemePreference preference) {
  if (current_theme_name.empty()) current_theme_name = "Adwaita";
  bool const named_dark = ends_with_dark(current_theme_name);
  if (named_dark) current_theme_name.resize(current_theme_name.size() - 5);

  bool dark = false;
  switch (preference) {
    case ThemePreference::dark:
      dark = true;
      break;
    case ThemePreference::light:
      dark = false;
      break;
    case ThemePreference::system:
      if (desktop_scheme == "prefer-dark") {
        dark = true;
      } else if (desktop_scheme == "prefer-light") {
        dark = false;
      } else {
        // GTK4 without libadwaita commonly derives its effective variant from
        // the theme name. Prefer that concrete evidence over a stale boolean.
        dark = named_dark || gtk_prefers_dark;
      }
      break;
  }

  return {dark ? ColorScheme::dark : ColorScheme::light,
          current_theme_name + (dark ? "-dark" : "")};
}

ColorScheme ApplyTheme(ThemePreference preference) {
  GtkSettings* settings = gtk_settings_get_default();
  if (settings == nullptr) {
    return preference == ThemePreference::dark ? ColorScheme::dark
                                                : ColorScheme::light;
  }

  gchar* current_name = nullptr;
  gboolean prefers_dark = FALSE;
  g_object_get(settings, "gtk-theme-name", &current_name,
               "gtk-application-prefer-dark-theme", &prefers_dark, nullptr);
  ThemeSelection selection = ResolveTheme(
      current_name == nullptr ? std::string{} : std::string(current_name),
      desktop_color_scheme(), prefers_dark != FALSE, preference);
  g_free(current_name);

  gboolean const selected_dark =
      selection.color_scheme == ColorScheme::dark ? TRUE : FALSE;
  g_object_set(settings, "gtk-application-prefer-dark-theme", selected_dark,
               "gtk-theme-name", selection.gtk_theme_name.c_str(), nullptr);
  return selection.color_scheme;
}

}  // namespace rivet::linux_ui
