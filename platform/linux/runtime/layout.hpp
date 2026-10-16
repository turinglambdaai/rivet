#pragma once

#include <filesystem>
#include <optional>
#include <string>

namespace rivet::linux_runtime {

// The canonical Rivet runtime layout, in development trees and packaged
// applications alike (issue #246): runtime/*.boot plus res/core.zo under one
// stage root beside the executable. Products consume this discovery instead
// of re-deriving it — the layout is Rivet's contract, so the code that knows
// it lives here too.
struct RuntimeLayout {
  std::filesystem::path stage_root;
  std::filesystem::path resources;
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

// Reads the running executable's own path (/proc/self/exe).
std::filesystem::path executable_path();

// Looks for the canonical layout beside the running executable.
std::optional<RuntimeLayout> discover_layout();

// The same check against an explicit stage root — the injectable core used
// by tests and by hosts that stage a layout somewhere else.
std::optional<RuntimeLayout> discover_layout(
    std::filesystem::path const& stage_root);

// The missing-layout remediation message hosts display verbatim.
std::string const& layout_error_hint();

}  // namespace rivet::linux_runtime
