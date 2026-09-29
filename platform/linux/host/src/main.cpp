// Rivet Linux host scaffold — GTK4 window over one embedded Racket CS
// backend. Mirrors the WinUI scaffold: boot the runtime off the UI thread,
// render the counter State through the generated client, dispatch every
// completion back to the main loop before touching widgets.
#include <gtk/gtk.h>

#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <thread>

#include "GeneratedBackend.hpp"

namespace {

struct AppState {
  GtkLabel* status{nullptr};
  GtkLabel* count{nullptr};
  GtkButton* increment{nullptr};

  std::unique_ptr<rivet::linux::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::int64_t count{0};

  void set_status(std::string const& text) {
    gtk_label_set_text(status, text.c_str());
  }

  void set_count(std::int64_t value) {
    count = value;
    gtk_label_set_text(count, ("Count: " + std::to_string(value)).c_str());
  }
};

AppState g_state;

std::filesystem::path executable_path() {
  return std::filesystem::readlink("/proc/self/exe");
}

// Packaged apps keep Racket data under <prefix>/lib/fulcrum; `raco rivet
// dev` runs the staged executable directly, where runtime/res live next to
// the executable. Pick the first complete layout so both paths use exactly
// the same host binary.
struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
  std::filesystem::path root;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  std::filesystem::path const exe = executable_path();
  std::filesystem::path const roots[] = {
      exe.parent_path(),
      exe.parent_path() / ".." / "lib" / "fulcrum",
  };
  for (auto const& root : roots) {
    RuntimeLayout layout{
        root / "runtime" / "petite.boot",
        root / "runtime" / "scheme.boot",
        root / "runtime" / "racket.boot",
        root / "res" / "core.zo",
        root,
    };
    if (std::filesystem::exists(layout.petite_boot) &&
        std::filesystem::exists(layout.scheme_boot) &&
        std::filesystem::exists(layout.racket_boot) &&
        std::filesystem::exists(layout.core)) {
      return layout;
    }
  }
  return std::nullopt;
}

// g_idle_add needs a C function pointer; completion results travel as
// heap-allocated payloads and free themselves on arrival.
template <typename T>
int deliver_to_main_loop(void (*apply)(T*), void* raw) {
  return G_SOURCE_REMOVE;
}

struct IntResult {
  bool ok{false};
  std::int64_t value{0};
  std::string error;
};

int on_count_delivered(gpointer user_data) {
  std::unique_ptr<IntResult> result(static_cast<IntResult*>(user_data));
  if (result->ok) {
    g_state.set_count(result->value);
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.increment), TRUE);
  } else {
    g_state.set_status("State error: " + result->error);
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.increment), TRUE);
  }
  return G_SOURCE_REMOVE;
}

int on_backend_ready(gpointer user_data) {
  // Ownership of the started backend and its generated API move to the app
  // lifetime here, on the main loop thread.
  auto* parts = static_cast<std::pair<rivet::linux::Backend*,
                                      rivet_app::API*>*>(user_data);
  g_state.backend.reset(parts->first);
  g_state.api.reset(parts->second);
  delete parts;

  g_state.set_status("Embedded Racket CS is ready");
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.increment), TRUE);
  g_state.api->get_counter_async([](rivet_app::Result<std::int64_t> result) {
    auto* delivered = new IntResult{result.ok, result.value, result.error};
    g_idle_add(on_count_delivered, delivered);
  });
  return G_SOURCE_REMOVE;
}

int on_backend_failed(gpointer user_data) {
  std::unique_ptr<std::string> message(static_cast<std::string*>(user_data));
  g_state.set_status("Backend error: " + *message);
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    g_state.set_status(
        "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
        "the executable. Build with raco rivet build/dev.");
    return;
  }

  rivet::linux::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.dll_dir = (layout->root / "runtime").string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  // Booting the embedded runtime blocks on file I/O; only startup runs off
  // the main loop. Everything after completion dispatches back through
  // g_idle_add.
  std::thread([config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux::Backend>(std::move(config));
    try {
      backend->start();
      // Build the API view first (needs the object), then release ownership
      // into the pair that on_backend_ready adopts.
      auto* parts = new std::pair<rivet::linux::Backend*, rivet_app::API*>(
          backend.get(), new rivet_app::API(*backend));
      backend.release();
      g_idle_add(on_backend_ready, parts);
    } catch (std::exception const& e) {
      g_idle_add(on_backend_failed, new std::string(e.what()));
    }
  }).detach();
}

void on_increment_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.increment), FALSE);
  auto const next = g_state.count + 1;
  g_state.api->set_counter_async(next,
                                 [](rivet_app::Result<std::int64_t> result) {
                                   auto* delivered =
                                       new IntResult{result.ok, result.value,
                                                     result.error};
                                   g_idle_add(on_count_delivered, delivered);
                                 });
}

void on_activate(GtkApplication* app, gpointer) {
  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "Rivet — Racket + GTK4");
  gtk_window_set_default_size(GTK_WINDOW(window), 460, 320);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_widget_set_margin_top(root, 40);
  gtk_widget_set_margin_bottom(root, 40);
  gtk_widget_set_valign(root, GTK_ALIGN_CENTER);
  gtk_widget_set_halign(root, GTK_ALIGN_CENTER);

  auto* title = gtk_label_new("Rivet");
  gtk_widget_add_css_class(title, "title-1");
  auto* subtitle = gtk_label_new("Racket + GTK4");
  gtk_widget_add_css_class(subtitle, "dim-label");
  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_widget_add_css_class(status, "dim-label");
  auto* count = gtk_label_new("Count: 0");
  gtk_widget_add_css_class(count, "title-2");
  auto* increment = gtk_button_new_with_label("Increment in Racket");
  gtk_widget_set_sensitive(increment, FALSE);
  gtk_widget_set_hexpand(increment, TRUE);

  gtk_box_append(GTK_BOX(root), title);
  gtk_box_append(GTK_BOX(root), subtitle);
  gtk_box_append(GTK_BOX(root), status);
  gtk_box_append(GTK_BOX(root), count);
  gtk_box_append(GTK_BOX(root), increment);
  gtk_window_set_child(GTK_WINDOW(window), root);

  g_state.status = GTK_LABEL(status);
  g_state.count = GTK_LABEL(count);
  g_state.increment = GTK_BUTTON(increment);
  g_signal_connect(increment, "clicked", G_CALLBACK(on_increment_clicked),
                   nullptr);

  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  if (g_state.backend != nullptr) {
    g_state.backend->stop();
  }
}

}  // namespace

int main(int argc, char** argv) {
  auto* app = gtk_application_new("dev.rivet.host",
                                  G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
