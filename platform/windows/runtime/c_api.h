#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define RIVET_C_API __declspec(dllexport)
#define RIVET_C_CALL __cdecl
#else
#define RIVET_C_API
#define RIVET_C_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rivet_backend_handle_t* rivet_backend_handle;
typedef struct rivet_call_handle_t* rivet_call_handle;

typedef struct rivet_buffer {
  uint8_t* data;
  size_t size;
} rivet_buffer;

// UTF-8 configuration for the embedded Racket CS runtime. All strings are
// borrowed only for the duration of rivet_backend_create().
typedef struct rivet_runtime_config_utf8 {
  const char* executable_path;
  const char* petite_boot;
  const char* scheme_boot;
  const char* racket_boot;
  const char* backend_bundle;
  const char* module_name;
  const char* entry_symbol;
  const char* collects_dir;
  const char* config_dir;
  const char* dll_dir;
} rivet_runtime_config_utf8;

// Event value bytes use the same RVT1 value codec as RPC arguments/results.
typedef void(RIVET_C_CALL* rivet_event_callback)(
    void* context,
    const char* name_utf8,
    const uint8_t* value_bytes,
    size_t value_size);

// Functions return 0 on success. On failure, error_utf8 receives owned UTF-8
// bytes; release them with rivet_buffer_free().
RIVET_C_API int RIVET_C_CALL rivet_backend_create(
    const rivet_runtime_config_utf8* config,
    rivet_backend_handle* backend,
    rivet_buffer* error_utf8);
RIVET_C_API int RIVET_C_CALL rivet_backend_start(
    rivet_backend_handle backend,
    rivet_buffer* error_utf8);
RIVET_C_API void RIVET_C_CALL rivet_backend_stop(rivet_backend_handle backend);
RIVET_C_API int RIVET_C_CALL rivet_backend_running(rivet_backend_handle backend);
RIVET_C_API void RIVET_C_CALL rivet_backend_destroy(rivet_backend_handle backend);

RIVET_C_API void RIVET_C_CALL rivet_backend_set_event_callback(
    rivet_backend_handle backend,
    rivet_event_callback callback,
    void* context);

// arguments_value must be one RVT1-encoded List value containing only RPC
// arguments (the RPC name is supplied separately). begin_call is non-blocking.
RIVET_C_API int RIVET_C_CALL rivet_backend_begin_call(
    rivet_backend_handle backend,
    const char* rpc_name_utf8,
    const uint8_t* arguments_value,
    size_t arguments_size,
    rivet_call_handle* call,
    rivet_buffer* error_utf8);

// Waits for a call and returns one RVT1-encoded result value.
RIVET_C_API int RIVET_C_CALL rivet_call_wait(
    rivet_call_handle call,
    rivet_buffer* result_value,
    rivet_buffer* error_utf8);
RIVET_C_API void RIVET_C_CALL rivet_call_cancel(rivet_call_handle call);
RIVET_C_API void RIVET_C_CALL rivet_call_destroy(rivet_call_handle call);

RIVET_C_API void RIVET_C_CALL rivet_buffer_free(rivet_buffer* buffer);

#ifdef __cplusplus
}
#endif
