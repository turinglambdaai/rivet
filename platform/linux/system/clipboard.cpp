#include "system_services.hpp"

#include <stdexcept>
#include <utility>

#include <gdk/gdk.h>
#include <gio/gio.h>

namespace rivet::system {
namespace {

using TextHandler = Clipboard::TextHandler;

void ReadClipboardText(GdkClipboard* clipboard, TextHandler completion) {
  auto* retained = new TextHandler(std::move(completion));
  gdk_clipboard_read_text_async(
      clipboard, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer user_data) {
        std::unique_ptr<TextHandler> handler(
            static_cast<TextHandler*>(user_data));
        GError* error = nullptr;
        char* text = gdk_clipboard_read_text_finish(
            GDK_CLIPBOARD(source), result, &error);
        try {
          if (error != nullptr) {
            if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED)) {
              g_clear_error(&error);
              (*handler)(std::nullopt, {});
              return;
            }
            std::string const message = error->message ? error->message
                                                       : "clipboard read failed";
            g_clear_error(&error);
            (*handler)(std::nullopt, message);
          } else if (text != nullptr) {
            std::string value(text);
            g_free(text);
            text = nullptr;
            (*handler)(std::move(value), {});
          } else {
            (*handler)(std::nullopt, {});
          }
        } catch (...) {
          if (error != nullptr) g_error_free(error);
          if (text != nullptr) g_free(text);
          g_warning("Rivet clipboard callback failed");
        }
      },
      retained);
}

}  // namespace

struct Clipboard::Impl final : std::enable_shared_from_this<Clipboard::Impl> {
  GdkClipboard* clipboard = nullptr;
  gulong changed_signal = 0;
  std::uint64_t observation_generation = 0;
  ChangeHandler handler;

  Impl() {
    GdkDisplay* display = gdk_display_get_default();
    if (display == nullptr) {
      throw std::runtime_error(
          "clipboard requires an initialized GTK display");
    }
    clipboard = GDK_CLIPBOARD(
        g_object_ref(gdk_display_get_clipboard(display)));
    changed_signal = g_signal_connect(
        clipboard, "changed",
        G_CALLBACK(+[](GdkClipboard*, gpointer user_data) {
          auto* self = static_cast<Impl*>(user_data);
          if (!self->handler) return;
          std::uint64_t const generation = ++self->observation_generation;
          std::weak_ptr<Impl> weak = self->weak_from_this();
          ReadClipboardText(
              self->clipboard,
              [weak, generation](std::optional<std::string> text,
                                 std::string error) {
                auto owner = weak.lock();
                if (owner && generation == owner->observation_generation &&
                    owner->handler) {
                  auto handler = owner->handler;
                  handler(std::move(text), std::move(error));
                }
              });
        }),
        this);
  }

  ~Impl() {
    if (clipboard != nullptr) {
      if (changed_signal != 0) {
        g_signal_handler_disconnect(clipboard, changed_signal);
      }
      g_object_unref(clipboard);
    }
  }
};

bool Clipboard::available() { return gdk_display_get_default() != nullptr; }

Clipboard::Clipboard() : impl_(std::make_shared<Impl>()) {}

Clipboard::~Clipboard() = default;

void Clipboard::read_text(TextHandler completion) const {
  if (!completion) {
    throw std::invalid_argument("clipboard read completion must not be empty");
  }
  ReadClipboardText(impl_->clipboard, std::move(completion));
}

void Clipboard::write_text(std::string const& text) const {
  if (text.find('\0') != std::string::npos) {
    throw std::invalid_argument(
        "clipboard text must not contain NUL characters");
  }
  gdk_clipboard_set_text(impl_->clipboard, text.c_str());
}

void Clipboard::set_change_handler(ChangeHandler handler) {
  ++impl_->observation_generation;
  impl_->handler = std::move(handler);
}

}  // namespace rivet::system
