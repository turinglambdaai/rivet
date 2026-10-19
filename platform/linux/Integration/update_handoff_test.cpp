#include "update_handoff.hpp"

#include <sys/wait.h>
#include <unistd.h>

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <system_error>
#include <thread>

namespace {

using rivet::update::AppImageHandoff;
using rivet::update::AppImageHandoffOptions;
using rivet::update::DetectLinuxInstallKind;
using rivet::update::LinuxInstallKind;

std::string const application_id = "org.rivet.handoff-test";

std::string read_text(std::filesystem::path const& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(input)),
                     std::istreambuf_iterator<char>());
}

void write_executable(std::filesystem::path const& path,
                      std::string const& contents) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output << contents;
  output.close();
  assert(output);
  assert(::chmod(path.c_str(), 0755) == 0);
}

std::string sha256_of(std::filesystem::path const& path) {
  auto const command = "sha256sum '" + path.string() + "' 2>/dev/null";
  FILE* pipe = ::popen(command.c_str(), "r");
  assert(pipe != nullptr);
  char buffer[128];
  std::string line;
  while (std::fgets(buffer, sizeof(buffer), pipe) != nullptr) line += buffer;
  int const status = ::pclose(pipe);
  assert(status == 0);
  return line.substr(0, line.find(' '));
}

std::filesystem::path updates_root() {
  char const* state = std::getenv("XDG_STATE_HOME");
  assert(state != nullptr && state[0] != '\0');
  return std::filesystem::path(state) / "Rivet" / "updates" / application_id;
}

void scratch_workspace() {
  std::error_code ec;
  std::filesystem::remove_all(updates_root(), ec);
}

// The helper waits for its launching process to exit, so every scenario
// forks: the child calls LaunchReplacement (its own pid is the one polled)
// and then either exits immediately or lingers. Returns the child pid —
// the attempt directory is named after it.
pid_t launch_from_child(std::filesystem::path const& candidate,
                        std::filesystem::path const& target,
                        AppImageHandoffOptions const& options,
                        unsigned exit_timeout_seconds, int linger_seconds) {
  pid_t const child = ::fork();
  assert(child >= 0);
  if (child == 0) {
    try {
      AppImageHandoff::LaunchReplacement(application_id, candidate, target,
                                         nullptr, exit_timeout_seconds,
                                         options);
    } catch (...) {
      std::abort();
    }
    if (linger_seconds > 0) ::sleep(linger_seconds);
    ::_exit(0);
  }
  int status = 0;
  assert(::waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  return child;
}

std::filesystem::path journal_for(std::filesystem::path const& target) {
  return std::filesystem::path(target.string() + ".rivet-handoff-journal");
}

std::optional<std::filesystem::path> find_attempt(pid_t child) {
  std::error_code ec;
  for (auto const& entry :
       std::filesystem::directory_iterator(updates_root(), ec)) {
    if (!entry.is_directory(ec)) continue;
    if (entry.path().filename().string().rfind(std::to_string(child) + "-",
                                               0) == 0) {
      return entry.path();
    }
  }
  return std::nullopt;
}

struct Outcome {
  std::filesystem::path attempt;
  std::string failure;  // empty on a committed handoff
};

// A committed or rolled-back handoff deletes its journal; a failed one
// leaves the failure marker behind.
Outcome wait_for_outcome(pid_t child, std::filesystem::path const& target,
                         int timeout_seconds) {
  std::optional<std::filesystem::path> attempt;
  for (int waited = 0; waited < timeout_seconds * 20 && !attempt; ++waited) {
    attempt = find_attempt(child);
    if (!attempt) std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  if (!attempt) {
    std::cerr << "no handoff attempt directory appeared\n";
    std::abort();
  }
  auto const deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);
  for (;;) {
    auto const failure = *attempt / "failure.txt";
    if (std::filesystem::is_regular_file(failure)) {
      return Outcome{*attempt, read_text(failure)};
    }
    if (!std::filesystem::is_regular_file(journal_for(target))) {
      return Outcome{*attempt, std::string()};
    }
    if (std::chrono::steady_clock::now() > deadline) {
      std::cerr << "handoff never settled in " << attempt->string() << "\n";
      std::abort();
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
}

}  // namespace

int main() {
  assert(DetectLinuxInstallKind("/tmp/RivetHost", "/tmp/App.AppImage") ==
         LinuxInstallKind::appimage);
  assert(DetectLinuxInstallKind("/opt/example/RivetHost", "") ==
         LinuxInstallKind::package_manager);
  assert(DetectLinuxInstallKind("/usr/bin/example", "") ==
         LinuxInstallKind::package_manager);
  assert(DetectLinuxInstallKind("./RivetHost", "") ==
         LinuxInstallKind::portable);

  auto const workspace = std::filesystem::temp_directory_path() /
                         ("rivet-handoff-test-" + std::to_string(::getpid()));
  std::filesystem::create_directories(workspace);
  ::setenv("XDG_STATE_HOME", workspace.string().c_str(), 1);
  scratch_workspace();

  auto const old_appimage = workspace / "old.AppImage";
  auto const new_appimage = workspace / "new.AppImage";
  std::string const old_payload = "#!/bin/sh\nsleep 4\n";
  std::string const replacement_payload = "#!/bin/sh\nsleep 4\n";
  write_executable(old_appimage, old_payload);
  write_executable(new_appimage, replacement_payload);
  auto const digest = sha256_of(new_appimage);

  // Successful handoff: the replacement survives the settle window, the
  // backup is gone, no failure marker remains, and the target now holds the
  // candidate payload.
  {
    AppImageHandoffOptions options;
    options.version = "2.0.0";
    options.artifact_sha256 = digest;
    options.settle_seconds = 1;
    auto const child = launch_from_child(new_appimage, old_appimage, options, 10, 0);
    auto const outcome = wait_for_outcome(child, old_appimage, 30);
    assert(outcome.failure.empty());
    assert(read_text(old_appimage) == replacement_payload);
    assert(!std::filesystem::exists(old_appimage.string() + ".rivet-backup"));
    assert(!std::filesystem::exists(outcome.attempt / "failure.txt"));
  }

  scratch_workspace();
  write_executable(old_appimage, old_payload);
  write_executable(new_appimage, replacement_payload);

  // Unhealthy replacement rolls back to the previous AppImage and records
  // the failure for the next launch.
  {
    auto const crashing = workspace / "crashing.AppImage";
    write_executable(crashing, "#!/bin/sh\nexit 1\n");
    AppImageHandoffOptions options;
    options.version = "2.0.0";
    options.artifact_sha256 = sha256_of(crashing);
    options.settle_seconds = 1;
    auto const child = launch_from_child(crashing, old_appimage, options, 10, 0);
    auto const outcome = wait_for_outcome(child, old_appimage, 30);
    assert(outcome.failure == "replacement-unhealthy");
    assert(read_text(old_appimage) == old_payload);
    auto const consumed = AppImageHandoff::ConsumeFailure(application_id);
    assert(consumed && consumed->message == "replacement-unhealthy");
    assert(!AppImageHandoff::ConsumeFailure(application_id).has_value());
  }

  scratch_workspace();
  write_executable(old_appimage, old_payload);
  write_executable(new_appimage, replacement_payload);

  // With rollback forbidden by signed policy the failing replacement stays
  // in place and the marker names the policy.
  {
    auto const crashing = workspace / "crashing.AppImage";
    write_executable(crashing, "#!/bin/sh\nexit 1\n");
    AppImageHandoffOptions options;
    options.version = "2.0.0";
    options.artifact_sha256 = sha256_of(crashing);
    options.settle_seconds = 1;
    options.rollback_allowed = false;
    auto const child = launch_from_child(crashing, old_appimage, options, 10, 0);
    auto const outcome = wait_for_outcome(child, old_appimage, 30);
    assert(outcome.failure == "replacement-unhealthy-rollback-forbidden");
    assert(read_text(old_appimage) == "#!/bin/sh\nexit 1\n");
  }

  scratch_workspace();
  write_executable(old_appimage, old_payload);
  write_executable(new_appimage, replacement_payload);

  // A candidate that does not match its signed digest fails closed before
  // anything moves.
  {
    AppImageHandoffOptions options;
    options.version = "2.0.0";
    options.artifact_sha256 = std::string(64, '0');
    options.settle_seconds = 1;
    auto const child = launch_from_child(new_appimage, old_appimage, options, 10, 0);
    auto const outcome = wait_for_outcome(child, old_appimage, 30);
    assert(outcome.failure == "candidate-mismatch");
    assert(read_text(old_appimage) == old_payload);
  }

  scratch_workspace();
  write_executable(old_appimage, old_payload);
  write_executable(new_appimage, replacement_payload);

  // A launching process that misses its exit window is reported for the
  // next launch instead of letting the helper race a live application.
  {
    AppImageHandoffOptions options;
    options.version = "2.0.0";
    options.artifact_sha256 = digest;
    options.settle_seconds = 1;
    auto const child = launch_from_child(new_appimage, old_appimage, options, 1, 5);
    auto const outcome = wait_for_outcome(child, old_appimage, 30);
    assert(outcome.failure == "process-exit-timeout");
    assert(read_text(old_appimage) == old_payload);
  }

  scratch_workspace();
  std::filesystem::remove_all(workspace);

  return 0;
}
