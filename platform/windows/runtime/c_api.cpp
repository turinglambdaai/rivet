#include "c_api.h"

#include "backend.hpp"
#include "rivet/protocol.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <exception>
#include <filesystem>
#include <future>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

struct rivet_backend_handle_t {
  explicit rivet_backend_handle_t(rivet::windows::RacketRuntimeConfig config)
      : dll_dir(config.dll_dir), backend(std::move(config)) {}

  std::wstring dll_dir;
  std::vector<HMODULE> bundled_runtime_modules;
  rivet::windows::Backend backend;
  std::mutex callback_mutex;
  rivet_event_callback callback{};
  void* callback_context{};
};

struct rivet_call_handle_t {
  rivet_call_handle_t(rivet_backend_handle owner,
                      rivet::windows::PendingCall pending)
      : owner(owner), id(pending.id), result(std::move(pending.result)) {}

  rivet_backend_handle owner{};
  std::uint64_t id{};
  std::future<rivet::Value> result;
};

namespace {

class DllDirectoryRegistration {
 public:
  explicit DllDirectoryRegistration(std::filesystem::path const& directory) {
    cookie_ = ::AddDllDirectory(directory.c_str());
    if (cookie_ == nullptr) {
      throw std::runtime_error("AddDllDirectory failed with Win32 error " +
                               std::to_string(::GetLastError()));
    }
  }

  ~DllDirectoryRegistration() {
    if (cookie_ != nullptr) {
      (void)::RemoveDllDirectory(cookie_);
    }
  }

  DllDirectoryRegistration(DllDirectoryRegistration const&) = delete;
  DllDirectoryRegistration& operator=(DllDirectoryRegistration const&) = delete;

 private:
  DLL_DIRECTORY_COOKIE cookie_{nullptr};
};

void release_bundled_runtime_modules(std::vector<HMODULE>& modules) noexcept {
  for (auto it = modules.rbegin(); it != modules.rend(); ++it) {
    if (*it != nullptr) {
      (void)::FreeLibrary(*it);
    }
  }
  modules.clear();
}

bool is_dll(std::filesystem::path const& path) {
  return ::_wcsicmp(path.extension().c_str(), L".dll") == 0;
}

std::vector<HMODULE> preload_bundled_runtime_dlls(
    std::wstring const& runtime_directory) {
  std::vector<HMODULE> modules;
  if (runtime_directory.empty()) {
    return modules;
  }

  auto const runtime = std::filesystem::path(runtime_directory);
  if (!std::filesystem::is_directory(runtime)) {
    throw std::runtime_error("Rivet runtime directory does not exist");
  }

  // `raco ctool --runtime` places runtime-path resources (for example
  // db/sqlite3's sqlite3.dll) below the bundle's runtime directory. Racket
  // later opens those DLLs by absolute path. On Windows, dependencies of an
  // absolute-path LoadLibrary call are still resolved with the process DLL
  // search rules, so support DLLs staged at runtime/ are otherwise invisible
  // unless the host application mutates PATH.
  //
  // Do not change the host's process-wide default DLL search policy. Instead,
  // temporarily register runtime/ only for our explicit LoadLibraryEx calls,
  // preload the ctool-collected nested DLLs with safe search flags, then remove
  // the registration. The modules stay loaded until Racket shuts down, making
  // subsequent Racket FFI LoadLibrary calls deterministic and self-contained.
  DllDirectoryRegistration const runtime_search(runtime);

  std::vector<std::filesystem::path> candidates;
  for (auto const& entry : std::filesystem::recursive_directory_iterator(runtime)) {
    if (!entry.is_regular_file() || !is_dll(entry.path())) {
      continue;
    }
    if (entry.path().parent_path() == runtime) {
      // Top-level DLLs are dependency/search support files staged from the
      // Racket distribution. Only ctool runtime-path DLLs need preloading.
      continue;
    }
    candidates.push_back(entry.path());
  }
  std::sort(candidates.begin(), candidates.end());

  constexpr DWORD kLoadFlags =
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
  modules.reserve(candidates.size());
  try {
    for (auto const& path : candidates) {
      auto const module = ::LoadLibraryExW(path.c_str(), nullptr, kLoadFlags);
      if (module == nullptr) {
        throw std::runtime_error(
            "LoadLibraryExW failed for bundled Racket runtime DLL '" +
            path.u8string() + "' with Win32 error " +
            std::to_string(::GetLastError()));
      }
      modules.push_back(module);
    }
  } catch (...) {
    release_bundled_runtime_modules(modules);
    throw;
  }

  return modules;
}

void clear_buffer(rivet_buffer* buffer) noexcept {
  if (buffer != nullptr) {
    buffer->data = nullptr;
    buffer->size = 0;
  }
}

bool copy_buffer(const std::uint8_t* source,
                 std::size_t size,
                 rivet_buffer* destination) noexcept {
  if (destination == nullptr) {
    return false;
  }
  clear_buffer(destination);
  if (size == 0) {
    return true;
  }
  auto* memory = static_cast<std::uint8_t*>(std::malloc(size));
  if (memory == nullptr) {
    return false;
  }
  std::memcpy(memory, source, size);
  destination->data = memory;
  destination->size = size;
  return true;
}

bool copy_buffer(rivet::Bytes const& bytes, rivet_buffer* destination) noexcept {
  return copy_buffer(bytes.data(), bytes.size(), destination);
}

void set_error(std::string const& message, rivet_buffer* error) noexcept {
  if (error == nullptr) {
    return;
  }
  if (!copy_buffer(reinterpret_cast<std::uint8_t const*>(message.data()),
                   message.size(), error)) {
    clear_buffer(error);
  }
}

void set_current_error(rivet_buffer* error) noexcept {
  try {
    throw;
  } catch (std::exception const& e) {
    set_error(e.what(), error);
  } catch (...) {
    set_error("unknown Rivet native error", error);
  }
}

std::string required_string(const char* value, const char* field) {
  if (value == nullptr || value[0] == '\0') {
    throw std::invalid_argument(std::string("missing Rivet runtime field: ") + field);
  }
  return value;
}

std::string optional_string(const char* value, const char* fallback = "") {
  return value == nullptr ? fallback : value;
}

std::wstring utf8_to_wide(const char* value) {
  if (value == nullptr || value[0] == '\0') {
    return {};
  }
  auto const length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
  if (length <= 0) {
    throw std::runtime_error("invalid UTF-8 in Rivet dll_dir");
  }

  // `length` includes the terminating NUL. Reserve that slot for the Win32
  // conversion, then remove it from the std::wstring logical length.
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  auto const written = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result.data(), length);
  if (written != length) {
    throw std::runtime_error("failed to convert Rivet dll_dir to UTF-16");
  }
  result.resize(static_cast<std::size_t>(length - 1));
  return result;
}

rivet::windows::RacketRuntimeConfig convert_config(
    rivet_runtime_config_utf8 const& config) {
  rivet::windows::RacketRuntimeConfig result;
  result.executable_path = required_string(config.executable_path, "executable_path");
  result.petite_boot = required_string(config.petite_boot, "petite_boot");
  result.scheme_boot = required_string(config.scheme_boot, "scheme_boot");
  result.racket_boot = required_string(config.racket_boot, "racket_boot");
  result.backend_bundle = required_string(config.backend_bundle, "backend_bundle");
  result.module_name = optional_string(config.module_name, "backend");
  result.entry_symbol = optional_string(config.entry_symbol, "start");
  result.collects_dir = optional_string(config.collects_dir);
  result.config_dir = optional_string(config.config_dir);
  result.dll_dir = utf8_to_wide(config.dll_dir);
  return result;
}

rivet::Value::List decode_arguments(const std::uint8_t* bytes,
                                    std::size_t size) {
  if (bytes == nullptr || size == 0) {
    throw std::invalid_argument("Rivet RPC argument payload is empty");
  }
  rivet::Bytes encoded(bytes, bytes + size);
  auto decoded = rivet::decode_value(encoded);
  auto* values = std::get_if<rivet::Value::List>(&decoded.data);
  if (values == nullptr) {
    throw std::invalid_argument("Rivet RPC argument payload must encode a List");
  }
  return std::move(*values);
}

}  // namespace

extern "C" {

int RIVET_C_CALL rivet_backend_create(
    const rivet_runtime_config_utf8* config,
    rivet_backend_handle* backend,
    rivet_buffer* error_utf8) {
  clear_buffer(error_utf8);
  if (backend != nullptr) {
    *backend = nullptr;
  }
  try {
    if (config == nullptr || backend == nullptr) {
      throw std::invalid_argument("rivet_backend_create received a null argument");
    }
    auto handle = std::make_unique<rivet_backend_handle_t>(convert_config(*config));
    auto* raw = handle.get();
    raw->backend.set_event_handler([raw](std::string const& name,
                                          rivet::Value const& value) {
      rivet_event_callback callback = nullptr;
      void* context = nullptr;
      {
        std::lock_guard lock(raw->callback_mutex);
        callback = raw->callback;
        context = raw->callback_context;
      }
      if (callback == nullptr) {
        return;
      }
      try {
        auto encoded = rivet::encode_value(value);
        callback(context, name.c_str(), encoded.data(), encoded.size());
      } catch (...) {
        // Managed event handlers must never take down the native reader loop.
      }
    });
    *backend = handle.release();
    return 0;
  } catch (...) {
    set_current_error(error_utf8);
    return 1;
  }
}

int RIVET_C_CALL rivet_backend_start(
    rivet_backend_handle backend,
    rivet_buffer* error_utf8) {
  clear_buffer(error_utf8);
  try {
    if (backend == nullptr) {
      throw std::invalid_argument("rivet_backend_start received a null backend");
    }
    backend->bundled_runtime_modules =
        preload_bundled_runtime_dlls(backend->dll_dir);
    backend->backend.start();
    return 0;
  } catch (...) {
    if (backend != nullptr) {
      try {
        backend->backend.stop();
      } catch (...) {
      }
      release_bundled_runtime_modules(backend->bundled_runtime_modules);
    }
    set_current_error(error_utf8);
    return 1;
  }
}

void RIVET_C_CALL rivet_backend_stop(rivet_backend_handle backend) {
  if (backend == nullptr) {
    return;
  }
  try {
    backend->backend.stop();
  } catch (...) {
  }
  release_bundled_runtime_modules(backend->bundled_runtime_modules);
}

int RIVET_C_CALL rivet_backend_running(rivet_backend_handle backend) {
  return backend != nullptr && backend->backend.running() ? 1 : 0;
}

void RIVET_C_CALL rivet_backend_destroy(rivet_backend_handle backend) {
  if (backend == nullptr) {
    return;
  }
  try {
    backend->backend.set_event_handler({});
    backend->backend.stop();
  } catch (...) {
  }
  release_bundled_runtime_modules(backend->bundled_runtime_modules);
  delete backend;
}

void RIVET_C_CALL rivet_backend_set_event_callback(
    rivet_backend_handle backend,
    rivet_event_callback callback,
    void* context) {
  if (backend == nullptr) {
    return;
  }
  std::lock_guard lock(backend->callback_mutex);
  backend->callback = callback;
  backend->callback_context = context;
}

int RIVET_C_CALL rivet_backend_begin_call(
    rivet_backend_handle backend,
    const char* rpc_name_utf8,
    const std::uint8_t* arguments_value,
    std::size_t arguments_size,
    rivet_call_handle* call,
    rivet_buffer* error_utf8) {
  clear_buffer(error_utf8);
  if (call != nullptr) {
    *call = nullptr;
  }
  try {
    if (backend == nullptr || call == nullptr) {
      throw std::invalid_argument("rivet_backend_begin_call received a null argument");
    }
    auto rpc_name = required_string(rpc_name_utf8, "rpc_name");
    auto arguments = decode_arguments(arguments_value, arguments_size);
    auto pending = backend->backend.request(std::move(rpc_name), std::move(arguments));
    *call = new rivet_call_handle_t(backend, std::move(pending));
    return 0;
  } catch (...) {
    set_current_error(error_utf8);
    return 1;
  }
}

int RIVET_C_CALL rivet_call_wait(
    rivet_call_handle call,
    rivet_buffer* result_value,
    rivet_buffer* error_utf8) {
  clear_buffer(result_value);
  clear_buffer(error_utf8);
  try {
    if (call == nullptr || result_value == nullptr) {
      throw std::invalid_argument("rivet_call_wait received a null argument");
    }
    auto result = call->result.get();
    auto encoded = rivet::encode_value(result);
    if (!copy_buffer(encoded, result_value)) {
      throw std::bad_alloc();
    }
    return 0;
  } catch (...) {
    set_current_error(error_utf8);
    return 1;
  }
}

void RIVET_C_CALL rivet_call_cancel(rivet_call_handle call) {
  if (call == nullptr || call->owner == nullptr) {
    return;
  }
  try {
    call->owner->backend.cancel(call->id);
  } catch (...) {
  }
}

void RIVET_C_CALL rivet_call_destroy(rivet_call_handle call) {
  delete call;
}

void RIVET_C_CALL rivet_buffer_free(rivet_buffer* buffer) {
  if (buffer == nullptr) {
    return;
  }
  std::free(buffer->data);
  clear_buffer(buffer);
}

}  // extern "C"
