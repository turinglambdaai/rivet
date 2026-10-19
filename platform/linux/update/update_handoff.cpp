#include "update_handoff.hpp"

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <system_error>
#include <vector>

namespace rivet::update {
namespace {

std::string safe_component(std::string const& value) {
  std::string cleaned;
  cleaned.reserve(value.size());
  for (char const ch : value) {
    cleaned.push_back(std::isalnum(static_cast<unsigned char>(ch)) || ch == '.' ||
                              ch == '_' || ch == '-'
                          ? ch
                          : '_');
  }
  if (cleaned.empty() || cleaned == "." || cleaned == "..") {
    throw std::invalid_argument("application id has no safe path component");
  }
  return cleaned;
}

// Paths, ids, versions, and digests travel both into the generated shell
// script and into its JSON journal lines, so anything that could terminate a
// quoted shell word, start a parameter expansion, or close a JSON string is
// rejected up front instead of escaped. Everyday installation paths —
// spaces, Unicode, hyphens — pass unchanged.
void reject_unsafe_text(char const* what, std::string const& value) {
  for (char const ch : value) {
    auto const byte = static_cast<unsigned char>(ch);
    if (byte < 0x20 || ch == '"' || ch == '\'' || ch == '\\' || ch == '$' ||
        ch == '`') {
      throw std::invalid_argument(std::string(what) +
                                  " contains a character that is unsafe in a "
                                  "handoff script");
    }
  }
  if (value.empty()) {
    throw std::invalid_argument(std::string(what) + " is empty");
  }
}

std::filesystem::path state_root() {
  // XDG defaults: $XDG_STATE_HOME wins, $HOME/.local/state is the fallback.
  if (char const* state = std::getenv("XDG_STATE_HOME")) {
    if (state[0] != '\0') return std::filesystem::path(state);
  }
  if (char const* home = std::getenv("HOME")) {
    if (home[0] != '\0') {
      return std::filesystem::path(home) / ".local" / "state";
    }
  }
  throw std::runtime_error(
      "neither XDG_STATE_HOME nor HOME is set; cannot place the update "
      "handoff state directory");
}

std::filesystem::path update_root(std::string const& application_id) {
  auto root = state_root() / "Rivet" / "updates" / safe_component(application_id);
  std::error_code ec;
  std::filesystem::create_directories(root, ec);
  if (ec) {
    throw std::system_error(ec, "could not create the update handoff root");
  }
  return root;
}

std::string absolute_text(std::filesystem::path const& value) {
  return std::filesystem::absolute(value).lexically_normal().generic_string();
}

std::string json_string(std::string const& value) {
  // reject_unsafe_text already removed the characters JSON would escape;
  // this stays defensive for future callers.
  std::string escaped;
  escaped.reserve(value.size() + 2);
  escaped.push_back('"');
  for (char const ch : value) {
    switch (ch) {
      case '"': escaped += "\\\""; break;
      case '\\': escaped += "\\\\"; break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x",
                        static_cast<unsigned>(static_cast<unsigned char>(ch)));
          escaped += buffer;
        } else {
          escaped.push_back(ch);
        }
    }
  }
  escaped.push_back('"');
  return escaped;
}

std::string journal_line(char const* phase,
                         std::string const& application_id,
                         std::string const& version,
                         std::string const& artifact_sha256,
                         std::string const& downloaded,
                         std::string const& backup) {
  // Field names and phases mirror rivet/distribution's install journal
  // (schema 1) so an interrupted handoff is recoverable with
  // recover-platform-installation! once the caller rebuilds the plan.
  std::string digest = artifact_sha256;
  for (auto& ch : digest) ch = static_cast<char>(std::tolower(
                                   static_cast<unsigned char>(ch)));
  return "{\"schema\":1,\"application_id\":" + json_string(application_id) +
         ",\"version\":" + json_string(version) +
         ",\"artifact_sha256\":" + json_string(digest) +
         ",\"downloaded_path\":" + json_string(downloaded) +
         ",\"backup_path\":" + json_string(backup) +
         ",\"phase\":\"" + phase + "\"}";
}

std::string sh_single_quoted(std::string const& value) {
  // reject_unsafe_text has already rejected the quote character, so plain
  // single quotes are inert even for arguments containing spaces.
  return "'" + value + "'";
}

std::string journal_writer(char const* phase,
                           std::string const& record) {
  return std::string("    ") + phase + ") printf '%s\\n' " +
         sh_single_quoted(record) + " > \"$RIVET_JOURNAL\" ;;\n";
}

std::string handoff_script(std::string const& application_id,
                           std::string const& version,
                           std::string const& artifact_sha256,
                           std::string const& downloaded,
                           std::string const& backup,
                           unsigned exit_timeout_seconds,
                           unsigned settle_seconds,
                           bool rollback_allowed,
                           std::vector<std::string> const& relaunch_arguments) {
  // The journal records every phase the runtime transaction would write, so
  // a handoff that dies mid-flight stays auditable by the shared recovery
  // tooling. Phases that never ran simply never reach the file.
  std::string writers;
  for (char const* phase :
       {"prepared", "installing", "installed", "restarting", "restarted",
        "checking", "healthy", "committing", "committed", "rollback-started",
        "rolled-back", "rollback-failed"}) {
    writers += journal_writer(phase, application_id, version, artifact_sha256,
                              downloaded, backup);
  }

  std::string arguments;
  for (auto const& argument : relaunch_arguments) {
    reject_unsafe_text("relaunch argument", argument);
    arguments += " " + sh_single_quoted(argument);
  }

  std::string script;
  script += "#!/bin/sh\n";
  script += "# Rivet AppImage handoff - generated; safe to delete.\n";
  script += "# Performs the same atomic replace and journal phases as\n";
  script += "# execute-platform-installation!, out of process, so the\n";
  script += "# updating application can exit before its own files move.\n";
  script += "set -u\n";
  script += "RIVET_TARGET=\"$1\"\n";
  script += "RIVET_BACKUP=\"$2\"\n";
  script += "RIVET_EMPTY=\"$3\"\n";
  script += "RIVET_STAGING=\"$4\"\n";
  script += "RIVET_JOURNAL=\"$5\"\n";
  script += "RIVET_FAILURE=\"$6\"\n";
  script += "RIVET_CANDIDATE=\"$7\"\n";
  script += "RIVET_OLD_PID=\"$8\"\n";
  script += "RIVET_LOCK=\"$9\"\n";
  script += "rivet_write_journal() {\n  case \"$1\" in\n" + writers +
            "  esac\n}\n";
  script += "rivet_fail() {\n";
  script += "  printf '%s\\n' \"$1\" > \"$RIVET_FAILURE\"\n";
  script += "  exit 1\n";
  script += "}\n";
  // A missing owner PID means the lock is stale from a dead helper; a live
  // owner means another handoff owns the installation right now.
  script += "rivet_lock_acquired() {\n";
  script += "  if mkdir \"$RIVET_LOCK\" 2>/dev/null; then\n";
  script += "    printf '%s\\n' \"$RIVET_OLD_PID\" > \"$RIVET_LOCK/pid\"\n";
  script += "    return 0\n";
  script += "  fi\n";
  script += "  RIVET_OTHER=$(cat \"$RIVET_LOCK/pid\" 2>/dev/null)\n";
  script += "  if [ -n \"$RIVET_OTHER\" ] && ! kill -0 \"$RIVET_OTHER\" "
            "2>/dev/null; then\n";
  script += "    rm -rf \"$RIVET_LOCK\"\n";
  script += "    if mkdir \"$RIVET_LOCK\" 2>/dev/null; then\n";
  script += "      printf '%s\\n' \"$RIVET_OLD_PID\" > \"$RIVET_LOCK/pid\"\n";
  script += "      return 0\n";
  script += "    fi\n";
  script += "  fi\n";
  script += "  return 1\n";
  script += "}\n";
  script += "if ! rivet_lock_acquired; then\n";
  script += "  rivet_fail transaction-busy\n";
  script += "fi\n";
  script += "trap 'rm -rf \"$RIVET_LOCK\"' EXIT\n";
  script += "# A previous handoff that died between the two renames must not\n";
  script += "# leave the launch path without an executable: bring the\n";
  script += "# installation back to a runnable state before starting.\n";
  script += "rivet_preflight() {\n";
  script += "  if [ ! -f \"$RIVET_TARGET\" ] && [ -f \"$RIVET_BACKUP\" ]; then\n";
  script += "    mv -f \"$RIVET_BACKUP\" \"$RIVET_TARGET\"\n";
  script += "  fi\n";
  script += "  # Target and backup together mean the swap completed but the\n";
  script += "  # commit did not; the target is already the verified candidate,\n";
  script += "  # so dropping the backup finishes that transaction.\n";
  script += "  if [ -f \"$RIVET_TARGET\" ] && [ -f \"$RIVET_BACKUP\" ]; then\n";
  script += "    rm -f \"$RIVET_BACKUP\"\n";
  script += "  fi\n";
  script += "  rm -rf \"$RIVET_STAGING\"\n";
  script += "  rm -f \"$RIVET_JOURNAL\"\n";
  script += "}\n";
  script += "rivet_preflight\n";
  script += "rivet_write_journal prepared\n";
  script += "rivet_n=0\n";
  script += "while kill -0 \"$RIVET_OLD_PID\" 2>/dev/null; do\n";
  script += "  if [ \"$rivet_n\" -ge " + std::to_string(
                                                    exit_timeout_seconds == 0
                                                        ? 1
                                                        : exit_timeout_seconds) +
            " ]; then\n";
  script += "    rivet_fail process-exit-timeout\n";
  script += "  fi\n";
  script += "  sleep 1\n";
  script += "  rivet_n=$((rivet_n + 1))\n";
  script += "done\n";
  script += "rivet_write_journal installing\n";
  script += "mkdir -p \"$RIVET_STAGING\"\n";
  script += "cp \"$RIVET_CANDIDATE\" "
            "\"$RIVET_STAGING/application.AppImage\" || rivet_fail "
            "staging-failed\n";
  script += "chmod 755 \"$RIVET_STAGING/application.AppImage\"\n";
  script += "RIVET_ACTUAL=$(sha256sum \"$RIVET_STAGING/application.AppImage\" "
            "2>/dev/null | cut -d' ' -f1)\n";
  script += "if [ \"$RIVET_ACTUAL\" != " + sh_single_quoted(artifact_sha256) +
            " ]; then\n";
  script += "  rivet_fail candidate-mismatch\n";
  script += "fi\n";
  script += "if [ -f \"$RIVET_TARGET\" ]; then\n";
  script += "  mv -f \"$RIVET_TARGET\" \"$RIVET_BACKUP\" || rivet_fail "
            "replace-backup-failed\n";
  script += "else\n";
  script += "  printf 'no previous installation\\n' > \"$RIVET_EMPTY\"\n";
  script += "fi\n";
  script += "if ! mv -f \"$RIVET_STAGING/application.AppImage\" "
            "\"$RIVET_TARGET\"; then\n";
  script += "  if [ " +
            std::string(rollback_allowed ? "'1' = '1'" : "'0' = '1'") +
            " ]; then\n";
  script += "    rivet_write_journal rollback-started\n";
  script += "    if [ -f \"$RIVET_BACKUP\" ]; then\n";
  script += "      rm -f \"$RIVET_TARGET\"\n";
  script += "      mv -f \"$RIVET_BACKUP\" \"$RIVET_TARGET\"\n";
  script += "    elif [ -f \"$RIVET_EMPTY\" ]; then\n";
  script += "      rm -f \"$RIVET_TARGET\" \"$RIVET_EMPTY\"\n";
  script += "    fi\n";
  script += "    rivet_write_journal rolled-back\n";
  script += "    rm -f \"$RIVET_JOURNAL\"\n";
  script += "  fi\n";
  script += "  rivet_fail replace-install-failed\n";
  script += "fi\n";
  script += "rivet_write_journal installed\n";
  script += "rivet_write_journal restarting\n";
  script += "\"$RIVET_TARGET\"" + arguments + " </dev/null &\n";
  script += "RIVET_NEW_PID=$!\n";
  script += "rivet_write_journal restarted\n";
  script += "rivet_write_journal checking\n";
  script += "sleep " + std::to_string(settle_seconds) + "\n";
  script += "if kill -0 \"$RIVET_NEW_PID\" 2>/dev/null; then\n";
  script += "  rivet_write_journal healthy\n";
  script += "  rivet_write_journal committing\n";
  script += "  rm -f \"$RIVET_BACKUP\" \"$RIVET_EMPTY\"\n";
  script += "  rivet_write_journal committed\n";
  script += "  rm -f \"$RIVET_JOURNAL\"\n";
  script += "  exit 0\n";
  script += "fi\n";
  script += "if [ " +
            std::string(rollback_allowed ? "'1' = '1'" : "'0' = '1'") +
            " ]; then\n";
  script += "  rivet_write_journal rollback-started\n";
  script += "  if [ -f \"$RIVET_BACKUP\" ]; then\n";
  script += "    rm -f \"$RIVET_TARGET\"\n";
  script += "    mv -f \"$RIVET_BACKUP\" \"$RIVET_TARGET\"\n";
  script += "  elif [ -f \"$RIVET_EMPTY\" ]; then\n";
  script += "    rm -f \"$RIVET_TARGET\" \"$RIVET_EMPTY\"\n";
  script += "  fi\n";
  script += "  rivet_write_journal rolled-back\n";
  script += "  rm -f \"$RIVET_JOURNAL\"\n";
  script += "  rivet_fail replacement-unhealthy\n";
  script += "else\n";
  script += "  rivet_fail replacement-unhealthy-rollback-forbidden\n";
  script += "fi\n";
  return script;
}

std::optional<std::filesystem::path> newest_failure(
    std::filesystem::path const& root) {
  std::optional<std::filesystem::path> result;
  std::filesystem::file_time_type newest{};
  std::error_code ec;
  for (auto const& entry : std::filesystem::directory_iterator(root, ec)) {
    auto marker = entry.path() / "failure.txt";
    if (!entry.is_directory(ec) || !std::filesystem::is_regular_file(marker, ec)) {
      continue;
    }
    auto stamp = std::filesystem::last_write_time(marker, ec);
    if (!ec && (!result || stamp > newest)) {
      result = marker;
      newest = stamp;
    }
  }
  return result;
}

// Detaches /bin/sh on the generated script. Returns only on success;
// failures throw std::system_error after cleaning the attempt directory.
void launch_detached(std::filesystem::path const& attempt,
                     std::filesystem::path const& script_path,
                     std::filesystem::path const& log_path,
                     std::vector<std::string> const& arguments) {
  int error_pipe[2];
  if (::pipe(error_pipe) != 0) {
    throw std::system_error(errno, std::generic_category(),
                            "could not create the handoff error pipe");
  }
  if (::fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
    auto const error = errno;
    ::close(error_pipe[0]);
    ::close(error_pipe[1]);
    throw std::system_error(error, std::generic_category(),
                            "could not guard the handoff error pipe");
  }

  std::vector<std::string> storage;
  storage.reserve(arguments.size() + 2);
  storage.push_back("sh");
  storage.push_back(script_path.string());
  for (auto const& argument : arguments) storage.push_back(argument);
  std::vector<char*> argv;
  argv.reserve(storage.size() + 1);
  for (auto& value : storage) argv.push_back(value.data());
  argv.push_back(nullptr);

  pid_t const child = ::fork();
  if (child < 0) {
    auto const error = errno;
    ::close(error_pipe[0]);
    ::close(error_pipe[1]);
    throw std::system_error(error, std::generic_category(),
                            "could not fork the AppImage handoff");
  }
  if (child == 0) {
    ::close(error_pipe[0]);
    int const devnull = ::open("/dev/null", O_RDONLY);
    if (devnull >= 0) {
      ::dup2(devnull, STDIN_FILENO);
      if (devnull != STDIN_FILENO) ::close(devnull);
    }
    int const log = ::open(log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND,
                           0600);
    if (log >= 0) {
      ::dup2(log, STDOUT_FILENO);
      ::dup2(log, STDERR_FILENO);
      if (log != STDOUT_FILENO && log != STDERR_FILENO) ::close(log);
    }
    ::setsid();
    ::chdir(attempt.c_str());
    ::execv("/bin/sh", argv.data());
    int const error = errno;
    ssize_t const ignored = ::write(error_pipe[1], &error, sizeof(error));
    static_cast<void>(ignored);
    ::_exit(127);
  }

  ::close(error_pipe[1]);
  int exec_error = 0;
  ssize_t const read_bytes =
      ::read(error_pipe[0], &exec_error, sizeof(exec_error));
  ::close(error_pipe[0]);
  if (read_bytes == static_cast<ssize_t>(sizeof(exec_error))) {
    int status = 0;
    ::waitpid(child, &status, 0);
    std::error_code ignored;
    std::filesystem::remove_all(attempt, ignored);
    throw std::system_error(exec_error, std::generic_category(),
                            "could not execute the AppImage handoff script");
  }
}

}  // namespace

std::optional<AppImageHandoff::Failure> AppImageHandoff::ConsumeFailure(
    std::string const& application_id) {
  auto const marker = newest_failure(update_root(application_id));
  if (!marker) return std::nullopt;
  std::ifstream input(*marker, std::ios::binary);
  std::string bytes((std::istreambuf_iterator<char>(input)),
                    std::istreambuf_iterator<char>());
  std::error_code ignored;
  std::filesystem::remove(*marker, ignored);
  if (!bytes.empty() && bytes.back() == '\n') bytes.pop_back();
  if (bytes.empty()) bytes = "update-install-failed";
  return Failure{bytes};
}

void AppImageHandoff::CleanupStaleAttempts(std::string const& application_id,
                                           unsigned max_age_hours) {
  auto const root = update_root(application_id);
  auto const cutoff = std::filesystem::file_time_type::clock::now() -
                      std::chrono::hours(max_age_hours);
  std::error_code ec;
  for (auto const& entry : std::filesystem::directory_iterator(root, ec)) {
    if (!entry.is_directory(ec)) continue;
    auto const stamp = entry.last_write_time(ec);
    if (!ec && stamp < cutoff) {
      std::filesystem::remove_all(entry.path(), ec);
      ec.clear();
    }
  }
}

void AppImageHandoff::LaunchReplacement(
    std::string const& application_id,
    std::filesystem::path const& verified_appimage,
    std::filesystem::path const& target_appimage,
    std::function<void()> release_lease,
    unsigned exit_timeout_seconds,
    AppImageHandoffOptions const& options) {
  reject_unsafe_text("application id", application_id);
  reject_unsafe_text("signed version", options.version);
  std::string artifact_sha256 = options.artifact_sha256;
  for (auto& ch : artifact_sha256) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  if (artifact_sha256.size() != 64) {
    throw std::invalid_argument(
        "signed artifact digest must be 64 hexadecimal characters");
  }
  for (char const ch : artifact_sha256) {
    if (!std::isxdigit(static_cast<unsigned char>(ch))) {
      throw std::invalid_argument(
          "signed artifact digest must be 64 hexadecimal characters");
    }
  }
  if (!verified_appimage.is_absolute() ||
      !std::filesystem::is_regular_file(verified_appimage)) {
    throw std::invalid_argument(
        "verified AppImage must be an absolute existing file");
  }
  if (!target_appimage.is_absolute()) {
    throw std::invalid_argument("target AppImage must be an absolute path");
  }

  auto const root = update_root(application_id);
  auto const now =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count();
  auto const attempt =
      root / (std::to_string(::getpid()) + "-" + std::to_string(now));
  std::error_code ec;
  std::filesystem::create_directories(attempt, ec);
  if (ec) {
    throw std::system_error(ec, "could not create the handoff attempt directory");
  }

  // The swap only renames within the target directory, so the candidate is
  // staged beside the target first — exactly what stage-appimage! does for
  // the in-process transaction. Same-filesystem renames stay atomic even
  // when the download cache lives on another mount.
  auto const target_text = absolute_text(target_appimage);
  std::filesystem::path const backup(target_text + ".rivet-backup");
  std::filesystem::path const staging(target_text + ".rivet-staging");
  std::filesystem::path const empty(target_text + ".rivet-backup.empty");
  std::filesystem::path const lock(target_text + ".rivet-handoff-lock");
  auto const script_path = attempt / "handoff.sh";
  auto const log_path = attempt / "handoff.log";
  auto const failure_path = attempt / "failure.txt";
  // Deterministic sibling path: the next launch checks exactly this file to
  // decide whether an interrupted handoff needs recovery, and the preflight
  // clears it once the installation is physically consistent again.
  std::filesystem::path const journal(target_text + ".rivet-handoff-journal");

  auto const script = handoff_script(
      application_id, options.version, artifact_sha256,
      absolute_text(verified_appimage), absolute_text(backup),
      exit_timeout_seconds, options.settle_seconds, options.rollback_allowed,
      options.relaunch_arguments);
  {
    std::ofstream output(script_path, std::ios::binary | std::ios::trunc);
    output.write(script.data(), static_cast<std::streamsize>(script.size()));
    output.close();
    if (!output) {
      std::error_code cleanup;
      std::filesystem::remove_all(attempt, cleanup);
      throw std::system_error(std::make_error_code(std::errc::io_error),
                              "could not write the AppImage handoff script");
    }
    if (::chmod(script_path.c_str(), 0700) != 0) {
      auto const error = errno;
      std::error_code cleanup;
      std::filesystem::remove_all(attempt, cleanup);
      throw std::system_error(error, std::generic_category(),
                              "could not guard the AppImage handoff script");
    }
  }

  std::vector<std::string> arguments;
  arguments.push_back(absolute_text(target_appimage));
  arguments.push_back(absolute_text(backup));
  arguments.push_back(absolute_text(empty));
  arguments.push_back(absolute_text(staging));
  arguments.push_back(absolute_text(journal));
  arguments.push_back(absolute_text(failure_path));
  arguments.push_back(absolute_text(verified_appimage));
  arguments.push_back(std::to_string(::getpid()));
  arguments.push_back(absolute_text(lock));

  try {
    launch_detached(attempt, script_path, log_path, arguments);
  } catch (...) {
    std::error_code cleanup;
    std::filesystem::remove_all(attempt, cleanup);
    throw;
  }
  if (release_lease) release_lease();
}

}  // namespace rivet::update
