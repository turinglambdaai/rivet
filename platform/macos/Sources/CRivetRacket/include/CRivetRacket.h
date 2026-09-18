#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rivet_racket_config {
  const char *exec_file;
  const char *petite_boot;
  const char *scheme_boot;
  const char *racket_boot;
  const char *core_zo;
  const char *module_name;
  const char *entry_name;
  const char *collects_dir;
  const char *config_dir;
} rivet_racket_config;

// Runs one embedded Racket CS instance on the calling thread. The function
// returns only after the backend exits. The file descriptors are owned by
// the Racket side once this call begins.
int rivet_racket_run(const rivet_racket_config *config, int in_fd, int out_fd);

#ifdef __cplusplus
}
#endif
