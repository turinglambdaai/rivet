#include "layout.hpp"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <unistd.h>

namespace fs = std::filesystem;

namespace {

void stage_layout(fs::path const& root, bool with_core) {
  fs::create_directories(root / "runtime");
  fs::create_directories(root / "res");
  for (char const* boot :
       {"petite.boot", "scheme.boot", "racket.boot"}) {
    std::ofstream out(root / "runtime" / boot);
    out << boot;
  }
  if (with_core) {
    std::ofstream out(root / "res" / "core.zo");
    out << "core";
  }
}

}  // namespace

int main() {
  auto scratch = fs::temp_directory_path() /
                 ("rivet-layout-test-" + std::to_string(::getpid()));
  fs::create_directories(scratch);

  // A complete layout is discovered with every path anchored at the root.
  auto complete = scratch / "complete";
  stage_layout(complete, true);
  auto layout = rivet::linux_runtime::discover_layout(complete);
  assert(layout.has_value());
  assert(layout->stage_root == complete);
  assert(layout->resources == complete / "res");
  assert(layout->petite_boot == complete / "runtime" / "petite.boot");
  assert(layout->scheme_boot == complete / "runtime" / "scheme.boot");
  assert(layout->racket_boot == complete / "runtime" / "racket.boot");
  assert(layout->core == complete / "res" / "core.zo");

  // A missing backend bundle is not a layout, with or without the boots.
  auto truncated = scratch / "truncated";
  stage_layout(truncated, false);
  assert(!rivet::linux_runtime::discover_layout(truncated).has_value());
  auto empty = scratch / "empty";
  fs::create_directories(empty);
  assert(!rivet::linux_runtime::discover_layout(empty).has_value());

  // The remediation hint stays displayable and names the expected files.
  auto const& hint = rivet::linux_runtime::layout_error_hint();
  assert(hint.find("runtime/*.boot") != std::string::npos);
  assert(hint.find("res/core.zo") != std::string::npos);

  // The executable's own path resolves on Linux (/proc/self/exe); other
  // hosts throw, and this test still exercises the root-based discovery.
  try {
    assert(!rivet::linux_runtime::executable_path().empty());
  } catch (...) {
  }

  std::error_code cleanup;
  fs::remove_all(scratch, cleanup);
  return 0;
}
