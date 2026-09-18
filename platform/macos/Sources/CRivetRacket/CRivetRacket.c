#include "CRivetRacket.h"

#include <string.h>

#include <chezscheme.h>
#include <racketcs.h>

int rivet_racket_run(const rivet_racket_config *config, int in_fd, int out_fd) {
  if (config == NULL || config->exec_file == NULL ||
      config->petite_boot == NULL || config->scheme_boot == NULL ||
      config->racket_boot == NULL || config->core_zo == NULL ||
      config->module_name == NULL || config->entry_name == NULL) {
    return 2;
  }

  racket_boot_arguments_t boot;
  memset(&boot, 0, sizeof(boot));
  boot.boot1_path = config->petite_boot;
  boot.boot2_path = config->scheme_boot;
  boot.boot3_path = config->racket_boot;
  boot.exec_file = config->exec_file;
  boot.collects_dir = config->collects_dir;
  boot.config_dir = config->config_dir;

  racket_boot(&boot);
  racket_embedded_load_file(config->core_zo, 1);

  ptr quote = Sstring_to_symbol("quote");
  ptr module = Sstring_to_symbol(config->module_name);
  ptr module_path = Scons(quote, Scons(module, Snil));
  ptr entry = Sstring_to_symbol(config->entry_name);

  // racket_dynamic_require uses racket_apply internally and therefore returns
  // a list of result values.
  ptr required = racket_dynamic_require(module_path, entry);
  ptr procedure = Scar(required);
  ptr args = Scons(Sfixnum(in_fd), Scons(Sfixnum(out_fd), Snil));

  (void)racket_apply(procedure, args);
  Sscheme_deinit();
  return 0;
}
