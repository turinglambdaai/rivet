#include "layout.hpp"

namespace rivet::linux_runtime {

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

std::optional<RuntimeLayout> discover_layout(
    std::filesystem::path const& stage_root) {
  RuntimeLayout layout;
  layout.stage_root = stage_root;
  layout.resources = stage_root / "res";
  layout.petite_boot = stage_root / "runtime" / "petite.boot";
  layout.scheme_boot = stage_root / "runtime" / "scheme.boot";
  layout.racket_boot = stage_root / "runtime" / "racket.boot";
  layout.core = stage_root / "res" / "core.zo";
  std::error_code probe;
  if (std::filesystem::exists(layout.petite_boot, probe) &&
      std::filesystem::exists(layout.scheme_boot, probe) &&
      std::filesystem::exists(layout.racket_boot, probe) &&
      std::filesystem::exists(layout.core, probe)) {
    return layout;
  }
  return std::nullopt;
}

std::optional<RuntimeLayout> discover_layout() {
  return discover_layout(executable_path().parent_path());
}

std::string const& layout_error_hint() {
  static std::string const hint =
      "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
      "the executable. Build with raco rivet build/dev.";
  return hint;
}

}  // namespace rivet::linux_runtime
