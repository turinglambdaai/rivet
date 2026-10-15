#pragma once

#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "rivet/device_session.hpp"
#include "rivet/protocol.hpp"

namespace rivet {

// Drives one accepted byte stream through the RVD1 preface on the calling
// thread. The caller owns TLS and the transport; the host never opens a
// connection and the preface decoder never sees ordinary RVT1 bytes. After
// the session server accepts the peer, the authenticated stream is lent to
// the application handler, which must bind the accepted scopes to the
// gateway — the host creates no alternate authorization path.
//
// Threading: `run` performs all reads and most writes on its calling thread.
// `confirm_pairing_on_desktop`, `reject_pairing_on_desktop`, and `cancel`
// are for other threads; writes they trigger are serialized through the
// host mutex. `cancel` wakes a desktop-decision wait but cannot unblock a
// blocking transport read — close the transport for that, exactly as the
// Apple host closes its connection on cancellation.
class DeviceSessionHost {
 public:
  using Clock = std::function<double()>;
  using ServerFactory =
      std::function<std::unique_ptr<DeviceSessionServer>(double started_at)>;
  // Receives the pairing code for the desktop user to compare. Never
  // confirms anything on the device's behalf.
  using PairingCodeHandler =
      std::function<void(SessionUuid const& attempt_id,
                         std::string const& verification_code,
                         double expires_at)>;
  using ApplicationHandler =
      std::function<void(SessionAcceptance const&, Transport&)>;

  DeviceSessionHost(Transport& transport, ServerFactory make_server,
                    PairingCodeHandler pairing_code_handler,
                    ApplicationHandler application_handler, Clock now,
                    double post_tls_timeout = 10.0);
  ~DeviceSessionHost();

  DeviceSessionHost(DeviceSessionHost const&) = delete;
  DeviceSessionHost& operator=(DeviceSessionHost const&) = delete;

  // Runs the preface and, after acceptance, lends the authenticated stream
  // to the application handler. Returns normally after a clean close (a
  // server Reject, a Close action, or `cancel`); throws
  // DeviceSessionHostError on post-TLS timeout and rethrows transport or
  // protocol failures.
  void run();

  // Desktop-user decisions while `run` waits in the pairing flow. They are
  // rejected with the state machine's own error when no pairing is active.
  std::vector<SessionServerAction> confirm_pairing_on_desktop(
      std::vector<std::string> const& granted_scope_names);
  std::vector<SessionServerAction> reject_pairing_on_desktop();

  // Idempotent. Requests a clean close and wakes any desktop-decision wait.
  void cancel();

 private:
  enum class Phase { Running, Closed };

  SessionMessage receive_message();
  // Both require mutex_ to be held.
  void write_locked(SessionMessage const& message);
  void execute(std::vector<SessionServerAction> const& actions,
               bool& saw_acceptance, bool& saw_close);
  void finish();

  Transport& transport_;
  ServerFactory make_server_;
  PairingCodeHandler pairing_code_handler_;
  ApplicationHandler application_handler_;
  Clock now_;
  double post_tls_timeout_;

  std::mutex mutex_;
  std::condition_variable decision_cv_;
  std::unique_ptr<DeviceSessionServer> server_;
  std::optional<SessionAcceptance> acceptance_;
  std::optional<double> pairing_expires_at_;
  Phase phase_ = Phase::Running;
  bool cancelled_ = false;
  bool finished_ = false;
};

// Thrown by `run` when the post-TLS deadline elapses. Other failures are
// rethrown as-is.
class DeviceSessionHostError : public std::runtime_error {
 public:
  explicit DeviceSessionHostError(char const* message)
      : std::runtime_error(message) {}
};

}  // namespace rivet
