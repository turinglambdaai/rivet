#include "theme.hpp"

#include <cassert>

using rivet::linux_ui::ColorScheme;
using rivet::linux_ui::ResolveTheme;
using rivet::linux_ui::ThemePreference;

int main() {
  auto selected = ResolveTheme("Adwaita-dark", "default", false,
                               ThemePreference::system);
  assert(selected.color_scheme == ColorScheme::dark);
  assert(selected.gtk_theme_name == "Adwaita-dark");

  selected = ResolveTheme("Adwaita-dark", "prefer-light", true,
                          ThemePreference::system);
  assert(selected.color_scheme == ColorScheme::light);
  assert(selected.gtk_theme_name == "Adwaita");

  selected = ResolveTheme("Adwaita", "prefer-dark", false,
                          ThemePreference::system);
  assert(selected.color_scheme == ColorScheme::dark);
  assert(selected.gtk_theme_name == "Adwaita-dark");

  selected = ResolveTheme("Yaru-dark", "prefer-dark", true,
                          ThemePreference::light);
  assert(selected.color_scheme == ColorScheme::light);
  assert(selected.gtk_theme_name == "Yaru");

  selected = ResolveTheme("Yaru", "prefer-light", false,
                          ThemePreference::dark);
  assert(selected.color_scheme == ColorScheme::dark);
  assert(selected.gtk_theme_name == "Yaru-dark");
}
