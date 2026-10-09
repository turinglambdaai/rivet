#pragma once

#include <string>

namespace rivet::linux_ui {

enum class ThemePreference { system, light, dark };
enum class ColorScheme { light, dark };

struct ThemeSelection final {
  ColorScheme color_scheme{ColorScheme::light};
  std::string gtk_theme_name;
};

// Pure resolver used by tests and by ApplyTheme. `desktop_color_scheme` uses
// org.gnome.desktop.interface values (prefer-dark, prefer-light, or default).
ThemeSelection ResolveTheme(std::string current_theme_name,
                            std::string desktop_color_scheme,
                            bool gtk_prefers_dark,
                            ThemePreference preference);

// Keep GTK's widget variant and an application's palette on the same side of
// the light/dark boundary. Call on GTK's main thread after activation, and
// again when an application-owned theme preference changes. The returned
// scheme is the palette the application should use for its own CSS.
ColorScheme ApplyTheme(
    ThemePreference preference = ThemePreference::system);

}  // namespace rivet::linux_ui
