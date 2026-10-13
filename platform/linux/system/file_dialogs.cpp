#include "system_services.hpp"

#include <algorithm>
#include <cctype>
#include <memory>
#include <utility>

#include <gtk/gtk.h>

namespace rivet::system {
namespace {

std::string NormalizeExtension(std::string extension) {
  auto first = extension.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  auto last = extension.find_last_not_of(" \t\r\n");
  extension = extension.substr(first, last - first + 1);
  if (!extension.empty() && extension.front() == '.') extension.erase(0, 1);
  if (extension.empty() ||
      extension.find_first_of("/\\*?[];") != std::string::npos) {
    return {};
  }
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](unsigned char value) {
                   return static_cast<char>(std::tolower(value));
                 });
  return extension;
}

void AddFilters(GtkFileDialog* dialog,
                std::vector<FileDialogFilter> const& filters) {
  GListStore* store = g_list_store_new(GTK_TYPE_FILE_FILTER);
  for (auto const& filter : filters) {
    GtkFileFilter* native_filter = gtk_file_filter_new();
    bool has_pattern = false;
    for (auto extension : filter.extensions) {
      extension = NormalizeExtension(std::move(extension));
      if (extension.empty()) continue;
      auto pattern = "*." + extension;
      gtk_file_filter_add_pattern(native_filter, pattern.c_str());
      has_pattern = true;
    }
    if (has_pattern) {
      if (!filter.label.empty()) {
        gtk_file_filter_set_name(native_filter, filter.label.c_str());
      }
      g_list_store_append(store, native_filter);
    }
    g_object_unref(native_filter);
  }
  gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(store));
  g_object_unref(store);
}

std::optional<std::string> LocalPath(GFile* file, std::string& error) {
  char* path = g_file_get_path(file);
  if (!path) {
    error = "selected item is not a local file";
    return std::nullopt;
  }
  std::string result(path);
  g_free(path);
  return result;
}

std::string ErrorMessage(GError* error) {
  if (!error) return "file dialog failed without an error message";
  std::string message = error->message ? error->message : "file dialog failed";
  g_error_free(error);
  return message;
}

bool Cancelled(GError* error) {
  return error && g_error_matches(error, GTK_DIALOG_ERROR,
                                  GTK_DIALOG_ERROR_DISMISSED);
}

struct OpenState final {
  FileDialogs::OpenHandler completion;
  bool multiple{};
  bool folders{};
};

struct SaveState final {
  FileDialogs::SaveHandler completion;
};

}  // namespace

bool FileDialogs::available() { return gdk_display_get_default() != nullptr; }

void FileDialogs::OpenFiles(
    GtkWindow* parent, std::string title, bool allow_multiple,
    bool select_folders, std::vector<FileDialogFilter> filters,
    OpenHandler completion) {
  if (!completion) return;
  if (!available()) {
    completion(std::nullopt, "file dialogs require an initialized GTK display");
    return;
  }

  GtkFileDialog* dialog = gtk_file_dialog_new();
  gtk_file_dialog_set_modal(dialog, true);
  if (!title.empty()) gtk_file_dialog_set_title(dialog, title.c_str());
  if (!select_folders) AddFilters(dialog, filters);
  auto* state = new OpenState{
      std::move(completion), allow_multiple, select_folders};
  auto callback = +[](GObject* source, GAsyncResult* result,
                      gpointer user_data) {
    std::unique_ptr<OpenState> state(static_cast<OpenState*>(user_data));
    auto* dialog = GTK_FILE_DIALOG(source);
    GError* error = nullptr;
    std::vector<std::string> paths;
    std::string path_error;

    if (state->multiple) {
      GListModel* files = state->folders
          ? gtk_file_dialog_select_multiple_folders_finish(dialog, result,
                                                            &error)
          : gtk_file_dialog_open_multiple_finish(dialog, result, &error);
      if (files) {
        guint count = g_list_model_get_n_items(files);
        paths.reserve(count);
        for (guint index = 0; index < count; ++index) {
          GFile* file = G_FILE(g_list_model_get_item(files, index));
          auto path = LocalPath(file, path_error);
          g_object_unref(file);
          if (!path) break;
          paths.push_back(std::move(*path));
        }
        g_object_unref(files);
      }
    } else {
      GFile* file = state->folders
          ? gtk_file_dialog_select_folder_finish(dialog, result, &error)
          : gtk_file_dialog_open_finish(dialog, result, &error);
      if (file) {
        auto path = LocalPath(file, path_error);
        g_object_unref(file);
        if (path) paths.push_back(std::move(*path));
      }
    }

    if (error) {
      bool cancelled = Cancelled(error);
      std::string message = cancelled ? std::string() : ErrorMessage(error);
      if (cancelled) g_error_free(error);
      state->completion(std::nullopt, std::move(message));
    } else if (!path_error.empty()) {
      state->completion(std::nullopt, std::move(path_error));
    } else {
      state->completion(std::move(paths), {});
    }
  };

  if (select_folders) {
    if (allow_multiple) {
      gtk_file_dialog_select_multiple_folders(dialog, parent, nullptr, callback,
                                               state);
    } else {
      gtk_file_dialog_select_folder(dialog, parent, nullptr, callback, state);
    }
  } else if (allow_multiple) {
    gtk_file_dialog_open_multiple(dialog, parent, nullptr, callback, state);
  } else {
    gtk_file_dialog_open(dialog, parent, nullptr, callback, state);
  }
  g_object_unref(dialog);
}

void FileDialogs::SaveFile(
    GtkWindow* parent, std::string title, std::string suggested_name,
    std::vector<FileDialogFilter> filters, SaveHandler completion) {
  if (!completion) return;
  if (!available()) {
    completion(std::nullopt, "file dialogs require an initialized GTK display");
    return;
  }

  GtkFileDialog* dialog = gtk_file_dialog_new();
  gtk_file_dialog_set_modal(dialog, true);
  if (!title.empty()) gtk_file_dialog_set_title(dialog, title.c_str());
  if (!suggested_name.empty()) {
    gtk_file_dialog_set_initial_name(dialog, suggested_name.c_str());
  }
  AddFilters(dialog, filters);
  auto* state = new SaveState{std::move(completion)};
  gtk_file_dialog_save(
      dialog, parent, nullptr,
      +[](GObject* source, GAsyncResult* result, gpointer user_data) {
        std::unique_ptr<SaveState> state(static_cast<SaveState*>(user_data));
        GError* error = nullptr;
        GFile* file = gtk_file_dialog_save_finish(
            GTK_FILE_DIALOG(source), result, &error);
        if (error) {
          bool cancelled = Cancelled(error);
          std::string message = cancelled ? std::string() : ErrorMessage(error);
          if (cancelled) g_error_free(error);
          state->completion(std::nullopt, std::move(message));
          return;
        }
        std::string path_error;
        auto path = file ? LocalPath(file, path_error) : std::nullopt;
        if (file) g_object_unref(file);
        state->completion(std::move(path), std::move(path_error));
      },
      state);
  g_object_unref(dialog);
}

}  // namespace rivet::system
