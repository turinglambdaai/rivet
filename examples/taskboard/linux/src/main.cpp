// First-party GTK4 taskboard over one embedded Racket CS backend. All widget
// access stays on the GLib main loop; generated-client completions are delivered
// with g_idle_add, and the long demo request remains explicitly cancellable.
#include <gtk/gtk.h>
#include <gdk/gdkkeysyms.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "GeneratedBackend.hpp"
#include "chart_area.hpp"
#include "system_services.hpp"
#include "theme.hpp"

namespace {

struct AppState {
  GtkWindow* window{nullptr};
  GtkLabel* status{nullptr};
  GtkListBox* task_list{nullptr};
  GtkLabel* task_title{nullptr};
  GtkLabel* task_status{nullptr};
  GtkLabel* task_notes{nullptr};
  GtkButton* new_task{nullptr};
  GtkButton* samples{nullptr};
  GtkButton* generate{nullptr};
  GtkButton* cancel{nullptr};
  GtkButton* advance{nullptr};
  GtkButton* remove{nullptr};
  GtkButton* edit_task{nullptr};
  GtkEntry* title_edit{nullptr};
  GtkWidget* title_edit_box{nullptr};
  GtkButton* save_task{nullptr};
  GtkButton* cancel_task_edit{nullptr};
  GtkLabel* title_edit_error{nullptr};
  bool task_busy{false};
  bool title_editing{false};
  bool title_save_pending{false};
  bool title_save_feedback_pending{false};
  std::optional<std::int64_t> editing_task_id;

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};
  std::vector<rivet_app::BoardTask> tasks;
  std::optional<std::int64_t> selected_id;
  std::optional<std::uint64_t> generation_request;
  std::unique_ptr<rivet::ui::ChartArea> chart;
  GtkButton* stream_toggle{nullptr};
  bool streaming{false};

  void set_status(std::string const& text) {
    gtk_label_set_text(status, text.c_str());
  }
};

AppState g_state;

void perform_orderly_shutdown();
void configure_chart();

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  auto const root = executable_path().parent_path();
  RuntimeLayout layout{root / "runtime/petite.boot", root / "runtime/scheme.boot",
                       root / "runtime/racket.boot", root / "res/core.zo"};
  if (std::filesystem::exists(layout.petite_boot) &&
      std::filesystem::exists(layout.scheme_boot) &&
      std::filesystem::exists(layout.racket_boot) &&
      std::filesystem::exists(layout.core)) {
    return layout;
  }
  return std::nullopt;
}

char const* status_text(rivet_app::TaskStatus status) {
  switch (status) {
    case rivet_app::TaskStatus::backlog: return "Backlog";
    case rivet_app::TaskStatus::active: return "In progress";
    case rivet_app::TaskStatus::done: return "Done";
  }
  return "Unknown";
}

void set_accessible_identity(GtkWidget* widget, char const* id,
                             char const* label) {
  gtk_widget_set_name(widget, id);
  gtk_accessible_update_property(GTK_ACCESSIBLE(widget),
                                 GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

void set_busy(bool busy) {
  g_state.task_busy = busy;
  bool const can_mutate = !busy && !g_state.title_editing;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.new_task), can_mutate);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.samples), can_mutate);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.generate), can_mutate);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.task_list), can_mutate);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.edit_task),
                           can_mutate && g_state.selected_id.has_value());
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.save_task),
                           g_state.title_editing && !busy);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.cancel_task_edit),
                           g_state.title_editing && !busy);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.title_edit),
                           g_state.title_editing && !busy);
  auto const selected = std::find_if(
      g_state.tasks.begin(), g_state.tasks.end(),
      [](auto const& task) {
        return g_state.selected_id && task.id == *g_state.selected_id;
      });
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.advance),
                           can_mutate && selected != g_state.tasks.end() &&
                               selected->status != rivet_app::TaskStatus::done);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.remove),
                           can_mutate && selected != g_state.tasks.end());
  gtk_widget_set_visible(GTK_WIDGET(g_state.cancel),
                         busy && g_state.generation_request.has_value());
}

void show_selected_task() {
  auto found = std::find_if(g_state.tasks.begin(), g_state.tasks.end(), [](auto const& task) {
    return g_state.selected_id && task.id == *g_state.selected_id;
  });
  if (found == g_state.tasks.end()) {
    gtk_label_set_text(g_state.task_title, "Select a task");
    gtk_label_set_text(g_state.task_status, "");
    gtk_label_set_text(g_state.task_notes,
                       "Task details are provided by the shared Racket backend.");
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.advance), FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.remove), FALSE);
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.edit_task), FALSE);
    return;
  }
  gtk_label_set_text(g_state.task_title, found->title.c_str());
  gtk_label_set_text(g_state.task_status, status_text(found->status));
  gtk_label_set_text(g_state.task_notes, found->notes.c_str());
  gtk_button_set_label(g_state.advance,
                       found->status == rivet_app::TaskStatus::backlog
                           ? "Start Task"
                           : "Mark Done");
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.advance),
                           !g_state.task_busy && !g_state.title_editing &&
                               found->status != rivet_app::TaskStatus::done);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.remove),
                           !g_state.task_busy && !g_state.title_editing);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.edit_task),
                           !g_state.task_busy && !g_state.title_editing);
}

void apply_tasks(std::vector<rivet_app::BoardTask> tasks,
                 std::optional<std::int64_t> preferred = std::nullopt) {
  g_state.tasks = std::move(tasks);
  while (auto* child = gtk_widget_get_first_child(GTK_WIDGET(g_state.task_list))) {
    gtk_list_box_remove(g_state.task_list, child);
  }
  for (auto const& task : g_state.tasks) {
    auto* label = gtk_label_new(task.title.c_str());
    gtk_label_set_xalign(GTK_LABEL(label), 0.0F);
    gtk_widget_set_margin_top(label, 10);
    gtk_widget_set_margin_bottom(label, 10);
    gtk_widget_set_margin_start(label, 12);
    gtk_widget_set_margin_end(label, 12);
    auto* row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), label);
    auto const row_id = "task-row-" + std::to_string(task.id);
    gtk_widget_set_name(row, row_id.c_str());
    gtk_accessible_update_property(GTK_ACCESSIBLE(row),
                                   GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   task.title.c_str(), -1);
    gtk_widget_set_tooltip_text(row, status_text(task.status));
    gtk_list_box_append(g_state.task_list, row);
  }
  g_state.selected_id = preferred;
  int selected_index = 0;
  bool found = false;
  for (std::size_t index = 0; index < g_state.tasks.size(); ++index) {
    if (preferred && g_state.tasks[index].id == *preferred) {
      selected_index = static_cast<int>(index);
      found = true;
      break;
    }
  }
  if (!g_state.tasks.empty()) {
    auto* row = gtk_list_box_get_row_at_index(g_state.task_list, found ? selected_index : 0);
    gtk_list_box_select_row(g_state.task_list, row);
  } else {
    g_state.selected_id.reset();
    show_selected_task();
  }
  g_state.generation_request.reset();
  set_busy(false);
}

struct TasksDelivery {
  std::vector<rivet_app::BoardTask> tasks;
  std::optional<std::int64_t> preferred;
  std::string error;
};

int on_tasks_delivered(gpointer user_data) {
  std::unique_ptr<TasksDelivery> delivered(static_cast<TasksDelivery*>(user_data));
  if (!delivered->error.empty()) {
    g_state.generation_request.reset();
    g_state.title_save_feedback_pending = false;
    set_busy(false);
    g_state.set_status("Backend error: " + delivered->error);
  } else {
    apply_tasks(std::move(delivered->tasks), delivered->preferred);
    if (g_state.title_save_feedback_pending) {
      g_state.title_save_feedback_pending = false;
      // A successful save must remain visible even after the following
      // list refresh; do not immediately replace it with "Loaded N tasks".
      g_state.set_status("Title updated for this session (resets on restart).");
    } else {
      g_state.set_status("Loaded " + std::to_string(g_state.tasks.size()) +
                         " tasks");
    }
  }
  return G_SOURCE_REMOVE;
}

void deliver_tasks(rivet_app::Result<std::vector<rivet_app::BoardTask>> result,
                   std::optional<std::int64_t> preferred = std::nullopt) {
  auto* delivered = new TasksDelivery;
  delivered->preferred = preferred;
  try {
    delivered->tasks = result.get();
  } catch (std::exception const& error) {
    delivered->error = error.what();
  } catch (...) {
    delivered->error = "unknown backend failure";
  }
  g_idle_add(on_tasks_delivered, delivered);
}

void load_tasks(std::optional<std::int64_t> preferred = std::nullopt) {
  if (g_state.api == nullptr) return;
  set_busy(true);
  (void)g_state.api->list_tasks_async(
      [preferred](auto result) { deliver_tasks(std::move(result), preferred); });
}

struct MutationDelivery {
  std::optional<std::int64_t> preferred;
  std::string error;
  std::string notification_title;
  std::string notification_body;
};

int on_mutation_delivered(gpointer user_data) {
  std::unique_ptr<MutationDelivery> delivered(
      static_cast<MutationDelivery*>(user_data));
  if (!delivered->error.empty()) {
    set_busy(false);
    g_state.set_status("Backend error: " + delivered->error);
  } else {
    if (!delivered->notification_body.empty()) {
      std::thread([title = delivered->notification_title,
                   body = delivered->notification_body] {
        try {
          if (rivet::system::Notifications::available()) {
            (void)rivet::system::Notifications::Notify(
                "Rivet Taskboard", "task-completed", title, body);
          }
        } catch (...) {
          // Notification denial or an unavailable session bus does not turn a
          // successful domain mutation into an application failure.
        }
      }).detach();
    }
    load_tasks(delivered->preferred);
  }
  return G_SOURCE_REMOVE;
}

template <typename T>
void deliver_mutation(rivet_app::Result<T> result,
                      std::optional<std::int64_t> preferred = std::nullopt,
                      std::string notification_title = {},
                      std::string notification_body = {}) {
  auto* delivered = new MutationDelivery;
  try {
    (void)result.get();
    delivered->preferred = preferred;
    delivered->notification_title = std::move(notification_title);
    delivered->notification_body = std::move(notification_body);
  } catch (std::exception const& error) {
    delivered->error = error.what();
  } catch (...) {
    delivered->error = "unknown backend failure";
  }
  g_idle_add(on_mutation_delivered, delivered);
}

int on_progress_delivered(gpointer user_data) {
  std::unique_ptr<std::string> message(static_cast<std::string*>(user_data));
  g_state.set_status(*message);
  return G_SOURCE_REMOVE;
}

int on_backend_finished(gpointer) {
  if (g_state.startup_thread.joinable()) g_state.startup_thread.join();
  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }
  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend) backend->stop();
    return G_SOURCE_REMOVE;
  }
  if (!error.empty() || !backend) {
    g_state.set_status("Backend error: " + (error.empty() ? "missing backend" : error));
    return G_SOURCE_REMOVE;
  }
  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);
  // racket_boot installs Racket CS signal handlers. Install Rivet's process
  // shutdown bridge after the Hello handshake so SIGTERM/SIGINT keep reaching
  // the native application's orderly close path.
  try {
    rivet::system::InstallShutdownHook(perform_orderly_shutdown);
  } catch (std::exception const& hook_error) {
    std::fputs((std::string{"shutdown hook unavailable: "} +
                hook_error.what() + "\n")
                   .c_str(),
               stderr);
  }
  g_state.set_status("Embedded Racket CS is ready");
  load_tasks();
  configure_chart();
  return G_SOURCE_REMOVE;
}

void on_stream_toggled(GtkButton*, gpointer);


// Specs, thresholds, and the initial window come from typed RPCs; the live
// samples then flow as chart batches. Completions arrive off the main loop
// and are dispatched with g_idle_add like every other async delivery here.
void configure_chart() {
  (void)g_state.api->timing_series_specs_async(
      [](rivet_app::Result<std::vector<rivet_app::TimingSeries>> result) {
        if (result.error) {
          return;
        }
        auto const& received = result.get();
        auto* specs = new std::vector<rivet::ui::ChartSeriesSpec>();
        for (auto const& timing : received) {
          specs->push_back({timing.id, timing.label, timing.color, timing.unit});
        }
        g_idle_add(
            [](gpointer data) -> gboolean {
              std::unique_ptr<std::vector<rivet::ui::ChartSeriesSpec>> owned(
                  static_cast<std::vector<rivet::ui::ChartSeriesSpec>*>(data));
              if (g_state.chart) {
                g_state.chart->set_series(std::move(*owned));
                g_state.chart->on_gap = [](std::string const& series) {
                  (void)g_state.api->timing_window_async(
                      series,
                      [series](rivet_app::Result<rivet_app::TimingWindow> window) {
                        if (window.error) {
                          return;
                        }
                        auto const& received = window.get();
                        struct WindowDelivery {
                          std::string series;
                          std::uint64_t watermark;
                          std::vector<rivet::chart::Sample> samples;
                        };
                        auto* delivery = new WindowDelivery{
                            series, static_cast<std::uint64_t>(received.watermark), {}};
                        for (auto const& sample : received.samples) {
                          delivery->samples.push_back({sample.ts, sample.value});
                        }
                        g_idle_add(
                            [](gpointer data) -> gboolean {
                              std::unique_ptr<WindowDelivery> owned(
                                  static_cast<WindowDelivery*>(data));
                              if (g_state.chart) {
                                g_state.chart->replace_series(owned->series,
                                                              std::move(owned->samples),
                                                              owned->watermark);
                              }
                              return G_SOURCE_REMOVE;
                            },
                            delivery);
                      });
                };
              }
              return G_SOURCE_REMOVE;
            },
            specs);
      });
  (void)g_state.api->timing_decoration_async(
      [](rivet_app::Result<std::vector<rivet_app::TimingThreshold>> result) {
        if (result.error) {
          return;
        }
        auto const& received = result.get();
        auto* thresholds = new std::vector<rivet::ui::ChartThreshold>();
        for (auto const& timing : received) {
          thresholds->push_back({timing.value, timing.label, timing.color});
        }
        g_idle_add(
            [](gpointer data) -> gboolean {
              std::unique_ptr<std::vector<rivet::ui::ChartThreshold>> owned(
                  static_cast<std::vector<rivet::ui::ChartThreshold>*>(data));
              if (g_state.chart) {
                g_state.chart->set_thresholds(std::move(*owned));
              }
              return G_SOURCE_REMOVE;
            },
            thresholds);
      });
  (void)g_state.api->timing_start_async([](rivet_app::Result<bool>) {});
  g_state.streaming = true;
  gtk_button_set_label(g_state.stream_toggle, "Stop Stream");
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout) {
    g_state.set_status("Missing runtime/*.boot and res/core.zo next to the executable");
    return;
  }
  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend = std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    backend->set_event_handler([](std::string const& name, rivet::Value const& value) {
      try {
        auto event = rivet_app::decode_event(name, value);
        if (auto progress = std::get_if<rivet_app::Operation_progressEvent>(&event)) {
          g_idle_add(on_progress_delivered, new std::string(progress->value.message));
        }
        if (auto batch = std::get_if<rivet_app::Chart_batchEvent>(&event)) {
          auto* envelope = new rivet_app::ChartBatchEnvelope(std::move(batch->value));
          g_idle_add(
              [](gpointer data) -> gboolean {
                std::unique_ptr<rivet_app::ChartBatchEnvelope> owned(
                    static_cast<rivet_app::ChartBatchEnvelope*>(data));
                if (g_state.chart) {
                  g_state.chart->append_batch(owned->series, owned->batch);
                }
                return G_SOURCE_REMOVE;
              },
              envelope);
        }
      } catch (...) {
      }
    });
    try {
      backend->start();
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_backend = std::move(backend);
    } catch (std::exception const& error) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = error.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}


// All draft widget access stays on the GLib main loop. An unsuccessful
// Racket RPC keeps the editor and its text untouched for a retry.
void finish_title_edit() {
  g_state.title_editing = false;
  g_state.title_save_pending = false;
  g_state.editing_task_id.reset();
  gtk_widget_set_visible(g_state.title_edit_box, FALSE);
  gtk_label_set_text(g_state.title_edit_error, "");
  set_busy(false);
  gtk_widget_grab_focus(GTK_WIDGET(g_state.edit_task));
}

void on_edit_clicked(GtkButton*, gpointer) {
  if (g_state.title_editing || g_state.task_busy || !g_state.api ||
      !g_state.selected_id) return;
  auto const found = std::find_if(g_state.tasks.begin(), g_state.tasks.end(),
      [](auto const& task) {
        return g_state.selected_id && task.id == *g_state.selected_id;
      });
  if (found == g_state.tasks.end()) return;
  g_state.title_editing = true;
  g_state.title_save_pending = false;
  g_state.editing_task_id = found->id;
  gtk_editable_set_text(GTK_EDITABLE(g_state.title_edit), found->title.c_str());
  gtk_label_set_text(g_state.title_edit_error, "");
  gtk_widget_set_visible(g_state.title_edit_box, TRUE);
  set_busy(false);
  g_state.set_status("Draft pending — Apply for this session or Discard draft.");
  gtk_widget_grab_focus(GTK_WIDGET(g_state.title_edit));
}

void on_discard_edit_clicked(GtkButton*, gpointer) {
  if (!g_state.title_editing || g_state.title_save_pending) return;
  finish_title_edit();
  g_state.set_status("Draft discarded — no changes saved.");
}

gboolean on_title_edit_key(GtkEventControllerKey*, guint keyval, guint,
                           GdkModifierType, gpointer) {
  // Enter is deliberately not a submit shortcut. GTK4's native GtkEntry
  // IME preedit must never become an accidental save action.
  if (keyval != GDK_KEY_Escape || !g_state.title_editing ||
      g_state.title_save_pending) return FALSE;
  on_discard_edit_clicked(nullptr, nullptr);
  return TRUE;
}

struct TitleEditDelivery {
  std::int64_t id;
  std::string error;
};

int on_title_edit_delivered(gpointer user_data) {
  std::unique_ptr<TitleEditDelivery> delivered(
      static_cast<TitleEditDelivery*>(user_data));
  if (g_state.shutting_down.load(std::memory_order_acquire) ||
      !g_state.title_editing || !g_state.editing_task_id ||
      *g_state.editing_task_id != delivered->id) return G_SOURCE_REMOVE;
  if (!delivered->error.empty()) {
    g_state.title_save_pending = false;
    set_busy(false);
    gtk_label_set_text(g_state.title_edit_error,
                       ("Update failed; draft retained: " + delivered->error).c_str());
    g_state.set_status("Update failed; draft retained — edit and retry.");
    gtk_widget_grab_focus(GTK_WIDGET(g_state.title_edit));
  } else {
    auto const id = delivered->id;
    finish_title_edit();
    g_state.title_save_feedback_pending = true;
    g_state.set_status("Title updated for this session (resets on restart).");
    load_tasks(id);
  }
  return G_SOURCE_REMOVE;
}

void on_save_edit_clicked(GtkButton*, gpointer) {
  if (!g_state.title_editing || g_state.title_save_pending ||
      !g_state.api || !g_state.editing_task_id) return;
  auto const found = std::find_if(g_state.tasks.begin(), g_state.tasks.end(),
      [](auto const& task) {
        return g_state.editing_task_id && task.id == *g_state.editing_task_id;
      });
  if (found == g_state.tasks.end()) return;
  auto const id = found->id;
  auto const draft = std::string(gtk_editable_get_text(GTK_EDITABLE(g_state.title_edit)));
  auto const notes = found->notes;
  auto const status = found->status;
  g_state.title_save_pending = true;
  gtk_label_set_text(g_state.title_edit_error, "");
  set_busy(true);
  g_state.set_status("Applying title for this session…");
  (void)g_state.api->update_task_async(
      id, draft, notes, status,
      [id](auto result) {
        auto* delivered = new TitleEditDelivery{id, {}};
        try {
          (void)result.get();
        } catch (std::exception const& error) {
          delivered->error = error.what();
        } catch (...) {
          delivered->error = "unknown backend failure";
        }
        g_idle_add(on_title_edit_delivered, delivered);
      });
}

void on_task_selected(GtkListBox*, GtkListBoxRow* row, gpointer) {
  if (g_state.title_editing || row == nullptr) return;
  int const index = gtk_list_box_row_get_index(row);
  if (index < 0 || static_cast<std::size_t>(index) >= g_state.tasks.size()) return;
  g_state.selected_id = g_state.tasks[static_cast<std::size_t>(index)].id;
  show_selected_task();
  if (g_state.api) {
    (void)g_state.api->select_task_async(*g_state.selected_id, [](auto) {});
  }
}

void on_new_clicked(GtkButton*, gpointer) {
  if (!g_state.api || g_state.title_editing) return;
  set_busy(true);
  (void)g_state.api->create_task_async(
      "New task", "Edit the Racket backend to make this workflow your own.",
      [](auto result) {
        std::optional<std::int64_t> id;
        try { id = result.get().id; }
        catch (...) { return deliver_mutation(std::move(result)); }
        deliver_mutation(std::move(result), id);
      });
}

void on_samples_clicked(GtkButton*, gpointer) {
  if (!g_state.api || g_state.title_editing) return;
  set_busy(true);
  (void)g_state.api->reload_sample_tasks_async(
      [](auto result) { deliver_tasks(std::move(result)); });
}

void on_generate_clicked(GtkButton*, gpointer) {
  if (!g_state.api || g_state.title_editing) return;
  set_busy(true);
  g_state.set_status("Preparing the bounded 1,000-row workload…");
  g_state.generation_request = g_state.api->generate_demo_tasks_async(
      1000, [](auto result) { deliver_tasks(std::move(result)); });
  gtk_widget_set_visible(GTK_WIDGET(g_state.cancel), TRUE);
}

void on_cancel_clicked(GtkButton*, gpointer) {
  if (g_state.backend && g_state.generation_request) {
    g_state.backend->cancel(*g_state.generation_request);
  }
}

void on_advance_clicked(GtkButton*, gpointer) {
  if (!g_state.api || !g_state.selected_id || g_state.title_editing) return;
  auto found = std::find_if(g_state.tasks.begin(), g_state.tasks.end(), [](auto const& task) {
    return task.id == *g_state.selected_id;
  });
  if (found == g_state.tasks.end()) return;
  auto const next = found->status == rivet_app::TaskStatus::backlog
                        ? rivet_app::TaskStatus::active
                        : rivet_app::TaskStatus::done;
  auto const id = found->id;
  auto const title = found->title;
  set_busy(true);
  (void)g_state.api->update_task_async(
      id, found->title, found->notes, next,
      [id, title, next](auto result) {
        deliver_mutation(std::move(result), id,
                         next == rivet_app::TaskStatus::done ? "Task completed" : "",
                         next == rivet_app::TaskStatus::done ? title : "");
      });
}

void on_stream_toggled(GtkButton*, gpointer) {
  // Click callbacks arrive on the GLib main loop, so the state flip and the
  // label update need no extra dispatch; only the async completion does.
  if (g_state.streaming) {
    (void)g_state.api->timing_stop_async([](rivet_app::Result<bool>) {});
  } else {
    (void)g_state.api->timing_start_async([](rivet_app::Result<bool>) {});
  }
  g_state.streaming = !g_state.streaming;
  gtk_button_set_label(g_state.stream_toggle,
                       g_state.streaming ? "Stop Stream" : "Start Stream");
}

void on_delete_clicked(GtkButton*, gpointer) {
  if (!g_state.api || !g_state.selected_id || g_state.title_editing) return;
  set_busy(true);
  (void)g_state.api->delete_task_async(
      *g_state.selected_id, [](auto result) { deliver_mutation(std::move(result)); });
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window) return gtk_window_present(g_state.window);
  (void)rivet::linux_ui::ApplyTheme();
  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "Rivet Taskboard — Racket + GTK4");
  gtk_window_set_default_size(GTK_WINDOW(window), 820, 520);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_margin_top(root, 20);
  gtk_widget_set_margin_bottom(root, 20);
  gtk_widget_set_margin_start(root, 20);
  gtk_widget_set_margin_end(root, 20);
  auto* title = gtk_label_new("Rivet Taskboard");
  gtk_widget_add_css_class(title, "title-1");
  gtk_label_set_xalign(GTK_LABEL(title), 0.0F);
  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0F);
  gtk_widget_add_css_class(status, "dim-label");

  auto* paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
  gtk_widget_set_vexpand(paned, TRUE);
  auto* task_list = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(task_list), GTK_SELECTION_SINGLE);
  gtk_widget_set_size_request(task_list, 280, -1);
  auto* scroller = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), task_list);
  gtk_paned_set_start_child(GTK_PANED(paned), scroller);

  auto* detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
  gtk_widget_set_margin_start(detail, 28);
  auto* task_title = gtk_label_new("Select a task");
  gtk_widget_add_css_class(task_title, "title-2");
  gtk_label_set_xalign(GTK_LABEL(task_title), 0.0F);
  gtk_label_set_wrap(GTK_LABEL(task_title), TRUE);
  auto* task_status = gtk_label_new("");
  gtk_label_set_xalign(GTK_LABEL(task_status), 0.0F);
  gtk_widget_add_css_class(task_status, "dim-label");
  auto* task_notes = gtk_label_new("Task details are provided by the shared Racket backend.");
  gtk_label_set_xalign(GTK_LABEL(task_notes), 0.0F);
  gtk_label_set_yalign(GTK_LABEL(task_notes), 0.0F);
  gtk_label_set_wrap(GTK_LABEL(task_notes), TRUE);
  gtk_widget_set_vexpand(task_notes, TRUE);
  auto* detail_actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  auto* edit_task = gtk_button_new_with_label("Edit title");
  auto* advance = gtk_button_new_with_label("Start Task");
  auto* remove = gtk_button_new_with_label("Delete");
  gtk_box_append(GTK_BOX(detail_actions), edit_task);
  gtk_box_append(GTK_BOX(detail_actions), advance);
  gtk_box_append(GTK_BOX(detail_actions), remove);
  // Vertical action layout keeps the explicit save/discard controls readable
  // at the minimum native pane width (the original row must not be clipped).
  auto* edit_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  auto* title_edit = gtk_entry_new();
  gtk_entry_set_max_length(GTK_ENTRY(title_edit), 4000);
  gtk_entry_set_placeholder_text(GTK_ENTRY(title_edit),
                                 "Task title (session-only)");
  gtk_widget_set_hexpand(title_edit, TRUE);
  auto* save_task = gtk_button_new_with_label("Apply for this session");
  auto* cancel_task_edit = gtk_button_new_with_label("Discard draft");
  auto* title_edit_error = gtk_label_new("");
  gtk_label_set_wrap(GTK_LABEL(title_edit_error), TRUE);
  gtk_label_set_xalign(GTK_LABEL(title_edit_error), 0.0F);
  gtk_widget_add_css_class(title_edit_error, "error");
  gtk_box_append(GTK_BOX(edit_box), title_edit);
  gtk_box_append(GTK_BOX(edit_box), save_task);
  gtk_box_append(GTK_BOX(edit_box), cancel_task_edit);
  gtk_box_append(GTK_BOX(edit_box), title_edit_error);
  gtk_widget_set_visible(edit_box, FALSE);
  gtk_box_append(GTK_BOX(detail), task_title);
  gtk_box_append(GTK_BOX(detail), task_status);
  gtk_box_append(GTK_BOX(detail), task_notes);
  gtk_box_append(GTK_BOX(detail), edit_box);
  gtk_box_append(GTK_BOX(detail), detail_actions);
  gtk_paned_set_end_child(GTK_PANED(paned), detail);

  auto* chart_frame = gtk_frame_new("Live timing series (chart data plane)");
  gtk_widget_set_size_request(chart_frame, -1, 190);
  g_state.chart = std::make_unique<rivet::ui::ChartArea>();
  g_state.chart->set_title("offsetFromMaster / meanPathDelay");
  auto* stream_toggle = gtk_button_new_with_label("Start Stream");
  auto* chart_actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  gtk_box_append(GTK_BOX(chart_actions), stream_toggle);
  auto* chart_column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_vexpand(g_state.chart->widget(), TRUE);
  gtk_box_append(GTK_BOX(chart_column), GTK_WIDGET(g_state.chart->widget()));
  gtk_box_append(GTK_BOX(chart_column), chart_actions);
  gtk_frame_set_child(GTK_FRAME(chart_frame), chart_column);

  auto* actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  auto* new_task = gtk_button_new_with_label("New Task");
  auto* samples = gtk_button_new_with_label("Reload Samples");
  auto* generate = gtk_button_new_with_label("Generate 1,000");
  auto* cancel = gtk_button_new_with_label("Cancel");
  gtk_widget_set_visible(cancel, FALSE);

  set_accessible_identity(status, "application-status", "Application status");
  set_accessible_identity(task_list, "task-list", "Tasks");
  set_accessible_identity(task_title, "task-title", "Selected task title");
  set_accessible_identity(task_status, "task-status", "Selected task status");
  set_accessible_identity(task_notes, "task-notes", "Selected task notes");
  set_accessible_identity(new_task, "new-task", "New task");
  set_accessible_identity(samples, "reload-samples", "Reload samples");
  set_accessible_identity(generate, "generate-demo", "Generate 1,000 tasks");
  set_accessible_identity(cancel, "cancel-generation", "Cancel generation");
  set_accessible_identity(advance, "advance-task", "Advance task status");
  set_accessible_identity(remove, "delete-task", "Delete task");
  set_accessible_identity(edit_task, "edit-task", "Edit title");
  set_accessible_identity(title_edit, "edit-task-title", "Task title draft");
  set_accessible_identity(save_task, "save-task", "Apply for this session");
  set_accessible_identity(cancel_task_edit, "cancel-task-edit", "Discard draft");
  set_accessible_identity(title_edit_error, "task-edit-error", "Task edit error");
  set_accessible_identity(g_state.chart->widget(), "timing-chart", "Live timing chart");
  set_accessible_identity(stream_toggle, "stream-toggle", "Toggle timing stream");
  gtk_box_append(GTK_BOX(actions), new_task);
  gtk_box_append(GTK_BOX(actions), samples);
  gtk_box_append(GTK_BOX(actions), generate);
  gtk_box_append(GTK_BOX(actions), cancel);

  gtk_box_append(GTK_BOX(root), title);
  gtk_box_append(GTK_BOX(root), status);
  gtk_box_append(GTK_BOX(root), paned);
  gtk_box_append(GTK_BOX(root), chart_frame);
  gtk_box_append(GTK_BOX(root), actions);
  gtk_window_set_child(GTK_WINDOW(window), root);

  g_state.window = GTK_WINDOW(window);
  g_state.status = GTK_LABEL(status);
  g_state.task_list = GTK_LIST_BOX(task_list);
  g_state.task_title = GTK_LABEL(task_title);
  g_state.task_status = GTK_LABEL(task_status);
  g_state.task_notes = GTK_LABEL(task_notes);
  g_state.new_task = GTK_BUTTON(new_task);
  g_state.samples = GTK_BUTTON(samples);
  g_state.generate = GTK_BUTTON(generate);
  g_state.cancel = GTK_BUTTON(cancel);
  g_state.advance = GTK_BUTTON(advance);
  g_state.remove = GTK_BUTTON(remove);
  g_state.edit_task = GTK_BUTTON(edit_task);
  g_state.title_edit = GTK_ENTRY(title_edit);
  g_state.title_edit_box = edit_box;
  g_state.save_task = GTK_BUTTON(save_task);
  g_state.cancel_task_edit = GTK_BUTTON(cancel_task_edit);
  g_state.title_edit_error = GTK_LABEL(title_edit_error);
  g_state.stream_toggle = GTK_BUTTON(stream_toggle);

  gtk_widget_set_sensitive(new_task, FALSE);
  gtk_widget_set_sensitive(samples, FALSE);
  gtk_widget_set_sensitive(generate, FALSE);
  gtk_widget_set_sensitive(advance, FALSE);
  gtk_widget_set_sensitive(remove, FALSE);
  gtk_widget_set_sensitive(edit_task, FALSE);
  auto* escape_keys = gtk_event_controller_key_new();
  g_signal_connect(escape_keys, "key-pressed",
                   G_CALLBACK(on_title_edit_key), nullptr);
  gtk_widget_add_controller(title_edit, escape_keys);
  g_signal_connect(edit_task, "clicked", G_CALLBACK(on_edit_clicked), nullptr);
  g_signal_connect(save_task, "clicked", G_CALLBACK(on_save_edit_clicked), nullptr);
  g_signal_connect(cancel_task_edit, "clicked",
                   G_CALLBACK(on_discard_edit_clicked), nullptr);
  g_signal_connect(task_list, "row-selected", G_CALLBACK(on_task_selected), nullptr);
  g_signal_connect(new_task, "clicked", G_CALLBACK(on_new_clicked), nullptr);
  g_signal_connect(samples, "clicked", G_CALLBACK(on_samples_clicked), nullptr);
  g_signal_connect(generate, "clicked", G_CALLBACK(on_generate_clicked), nullptr);
  g_signal_connect(cancel, "clicked", G_CALLBACK(on_cancel_clicked), nullptr);
  g_signal_connect(advance, "clicked", G_CALLBACK(on_advance_clicked), nullptr);
  g_signal_connect(remove, "clicked", G_CALLBACK(on_delete_clicked), nullptr);
  g_signal_connect(stream_toggle, "clicked", G_CALLBACK(on_stream_toggled), nullptr);

  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.startup_thread.joinable()) g_state.startup_thread.join();
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  {
    std::lock_guard lock(g_state.startup_mutex);
    startup_backend = std::move(g_state.startup_backend);
  }
  if (startup_backend) startup_backend->stop();
  if (g_state.backend) g_state.backend->stop();
}

// SIGTERM/SIGINT bypass the GTK main loop; run the same orderly shutdown
// the GTK shutdown signal would have run, then the hook hard-exits.
void perform_orderly_shutdown() { on_shutdown(nullptr, nullptr); }

}  // namespace

int main(int argc, char** argv) {
  g_set_application_name("Rivet Taskboard");
  auto* app = gtk_application_new("dev.rivet.taskboard", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
