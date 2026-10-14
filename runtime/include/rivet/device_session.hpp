#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "rivet/protocol.hpp"

namespace rivet {

// RVD1 v1 session preface: the bounded record dialect spoken over a device
// TLS connection before the ordinary RVT1 stream starts. The wire contract
// is pinned by rivet/tests/device-session-golden.txt and documented in
// docs/network-device-channel.md; Windows and Linux gateways terminate the
// server side of this preface through the state machine below.

inline constexpr std::uint8_t kSessionVersion = 1;
inline constexpr std::size_t kSessionMaximumRecordSize = 8 * 1024;
inline constexpr std::size_t kSessionMaximumPayloadSize =
    kSessionMaximumRecordSize - 8;
inline constexpr std::size_t kSessionMaximumScopeCount = 64;
inline constexpr std::size_t kSessionNonceSize = 32;
inline constexpr std::size_t kSessionCredentialSize = 32;
inline constexpr std::size_t kSessionFingerprintSize = 32;
inline constexpr std::size_t kSessionUuidSize = 16;
inline constexpr std::int64_t kSessionDefaultMaximumPayload = 512 * 1024;
inline constexpr std::int64_t kSessionDefaultMaximumPending = 64;

using SessionUuid = std::array<std::uint8_t, kSessionUuidSize>;

enum class SessionRejectCode {
  AuthenticationFailed,
  PairingUnavailable,
  PairingRejected,
  PairingExpired,
  ServerBusy,
  InternalError,
};

// The stable lowercase wire code carried by a Reject record.
std::string session_reject_code_string(SessionRejectCode code);
std::optional<SessionRejectCode> session_reject_code_from_string(
    std::string const& code);

struct SessionAuthenticate {
  std::string application_id;
  SessionUuid device_id{};
  Bytes client_nonce;
};

struct SessionAuthChallenge {
  Bytes server_nonce;
};

struct SessionAuthProof {
  Bytes proof;
};

struct SessionPairStart {
  std::string application_id;
  SessionUuid window_id{};
  std::string device_name;
  Bytes client_nonce;
};

struct SessionPairChallenge {
  SessionUuid attempt_id{};
  Bytes server_nonce;
};

struct SessionPairDecision {
  SessionUuid attempt_id{};
  bool confirmed{};
};

struct SessionAccept {
  SessionUuid session_id{};
  std::vector<std::string> scope_names;
  std::int64_t maximum_payload{};
  std::int64_t maximum_pending{};
};

struct SessionPaired {
  SessionUuid device_id{};
  Bytes credential;
  SessionUuid session_id{};
  std::vector<std::string> scope_names;
  std::int64_t maximum_payload{};
  std::int64_t maximum_pending{};
};

struct SessionReject {
  SessionRejectCode code{};
};

using SessionMessage = std::variant<SessionAuthenticate, SessionAuthChallenge,
                                    SessionAuthProof, SessionPairStart,
                                    SessionPairChallenge, SessionPairDecision,
                                    SessionAccept, SessionPaired, SessionReject>;

Bytes encode_session_record(SessionMessage const& message);
SessionMessage decode_session_record(Bytes const& record);

// Incrementally consumes an ordered byte stream while retaining at most one
// bounded record. Coalesced reads may yield several records; a malformed
// stream poisons the decoder.
class SessionRecordDecoder {
 public:
  std::vector<SessionMessage> append(Bytes const& bytes);
  void finish();

 private:
  void validate_header();

  Bytes buffer_;
  std::optional<std::size_t> expected_record_length_;
  bool failed_ = false;
};

// The authentication transcript: HMAC-SHA256 over the documented byte-exact
// concatenation. Both peers compute the same bytes from their shared values.
Bytes session_authentication_proof(Bytes const& credential,
                                   std::string const& application_id,
                                   Bytes const& server_fingerprint,
                                   SessionUuid const& device_id,
                                   Bytes const& client_nonce,
                                   Bytes const& server_nonce);

// The six-digit short authentication string both screens display during
// pairing, derived from the same transcript values.
std::string session_pairing_code(std::string const& application_id,
                                 Bytes const& server_fingerprint,
                                 Bytes const& client_nonce,
                                 Bytes const& server_nonce);

// API names appear in records and scope lists: non-empty ASCII-ish
// identifiers of at most 128 bytes limited to alphanumerics and `.-_`.
bool valid_device_api_name(std::string const& name);
// Display names are non-empty, at most 128 bytes, without leading, trailing,
// or embedded control characters, and without surrounding whitespace.
bool valid_device_display_name(std::string const& name);
// Scope lists are canonical: unique, bounded in count, API-name members.
bool valid_scope_names(std::vector<std::string> const& names);
// Canonical form: deduplicated, sorted by UTF-8 byte order.
std::vector<std::string> canonical_scope_names(std::vector<std::string> names);

// ---------------------------------------------------------------------------
// Server-side session state machine.

// Times are Unix-epoch seconds as doubles so hosts can feed their own clock
// through `receive`, `confirm_pairing_on_desktop`, and `expire`.

struct SessionPairedDevice {
  SessionUuid id{};
  std::string application_id;
  std::string name;
  std::vector<std::string> scope_names;
  Bytes server_fingerprint;
  double created_at{};
  double last_used_at{};
};

// Credential-bearing value used only at the secure-storage boundary.
struct SessionStoredPairing {
  SessionPairedDevice device;
  Bytes credential;
};

struct SessionPairingChallenge {
  SessionUuid attempt_id{};
  Bytes server_nonce;
  std::string verification_code;
  double expires_at{};
};

struct SessionPairingResult {
  SessionPairedDevice device;
  Bytes credential;
};

struct SessionAcceptance {
  SessionUuid session_id{};
  SessionUuid device_id{};
  std::string application_id;
  std::vector<std::string> scope_names;
  std::int64_t maximum_payload{};
  std::int64_t maximum_pending{};
};

// Errors thrown by coordinator implementations; `reject_code` maps them to
// the single public Reject code the server answers with.
enum class SessionPairingError {
  WindowAlreadyOpen,
  WindowUnavailable,
  WindowExpired,
  AttemptInProgress,
  AttemptUnavailable,
  InvalidDeviceName,
  AuthenticationFailed,
};

SessionRejectCode session_reject_code_for(SessionPairingError error);

// Platform secure storage for pairing credentials. `save` must be atomic;
// throwing from any member surfaces as an internal-error Reject.
class SessionPairingStore {
 public:
  virtual ~SessionPairingStore() = default;
  virtual std::optional<SessionStoredPairing> load(
      SessionUuid const& device_id) = 0;
  virtual void save(SessionStoredPairing const& pairing) = 0;
};

// Owns the five-minute pairing window and its single active attempt. The
// window policy is host-owned so the portable state machine stays
// transport- and storage-neutral.
class SessionPairingCoordinator {
 public:
  virtual ~SessionPairingCoordinator() = default;
  virtual SessionPairingChallenge begin_attempt(
      SessionUuid const& window_id, std::string const& device_name,
      Bytes const& client_nonce, double now) = 0;
  // Returns nullopt while still waiting for the desktop user.
  virtual std::optional<SessionPairingResult> confirm_on_desktop(
      SessionUuid const& window_id, SessionUuid const& attempt_id,
      std::vector<std::string> const& granted_scope_names, double now) = 0;
  // Returns nullopt while still waiting for the desktop user.
  virtual std::optional<SessionPairingResult> confirm_on_device(
      SessionUuid const& window_id, SessionUuid const& attempt_id,
      double now) = 0;
  virtual void fail_attempt(SessionUuid const& window_id,
                            SessionUuid const& attempt_id, double now) = 0;
  virtual void abandon_attempt(SessionUuid const& window_id,
                               SessionUuid const& attempt_id, double now) = 0;
  // Re-evaluates the window clock (closing an elapsed window) before the
  // server answers a pairing expiry with `pairing_expired`.
  virtual void expire_window(double now) = 0;
};

class SessionRandomBytes {
 public:
  virtual ~SessionRandomBytes() = default;
  virtual Bytes random_bytes(std::size_t count) = 0;
};

class SessionUuidGenerator {
 public:
  virtual ~SessionUuidGenerator() = default;
  virtual SessionUuid next_uuid() = 0;
};

struct SessionServerAction {
  struct Send {
    SessionMessage message;
  };
  struct ShowPairingCode {
    SessionUuid attempt_id{};
    std::string verification_code;
    double expires_at{};
  };
  struct Accepted {
    SessionAcceptance acceptance;
  };
  struct Close {};

  std::variant<Send, ShowPairingCode, Accepted, Close> action;
};

// Terminates the preface for one accepted device connection. The caller owns
// TLS and the ordered byte stream; the server never touches the network.
// After an Accepted action the stream carries ordinary RVT1 bytes.
class DeviceSessionServer {
 public:
  DeviceSessionServer(std::string application_id, Bytes server_fingerprint,
                      SessionPairingStore* store,
                      SessionPairingCoordinator* coordinator,
                      SessionRandomBytes* random, SessionUuidGenerator* uuids,
                      std::int64_t maximum_payload = kSessionDefaultMaximumPayload,
                      std::int64_t maximum_pending = kSessionDefaultMaximumPending,
                      double post_tls_timeout = 10.0, double started_at = 0.0);

  std::vector<SessionServerAction> receive(SessionMessage const& message,
                                           double now);
  std::vector<SessionServerAction> confirm_pairing_on_desktop(
      std::vector<std::string> const& granted_scope_names, double now);
  std::vector<SessionServerAction> reject_pairing_on_desktop(double now);
  std::vector<SessionServerAction> expire(double now);
  void disconnect(double now);
  std::optional<SessionAcceptance> const& acceptance() const { return acceptance_; }

 private:
  struct AuthenticationContext {
    std::string application_id;
    SessionUuid device_id{};
    Bytes client_nonce;
    Bytes server_nonce;
    Bytes credential;
    std::optional<SessionStoredPairing> candidate;
  };

  struct PairingContext {
    SessionUuid window_id{};
    SessionUuid attempt_id{};
    double expires_at{};
  };

  std::vector<SessionServerAction> begin_authentication(
      SessionAuthenticate const& authenticate, double now);
  std::vector<SessionServerAction> finish_authentication(
      Bytes const& proof, double now);
  std::vector<SessionServerAction> begin_pairing(SessionPairStart const& start,
                                                 double now);
  std::vector<SessionServerAction> handle_pair_decision(
      SessionPairDecision const& decision, double now);
  std::vector<SessionServerAction> finish_pairing(SessionPairingResult result);
  std::vector<SessionServerAction> close_with_reject(SessionRejectCode code);
  SessionAcceptance make_acceptance(SessionPairedDevice const& device);
  bool expired(double now) const;

  std::string application_id_;
  Bytes server_fingerprint_;
  SessionPairingStore* store_;
  SessionPairingCoordinator* coordinator_;
  SessionRandomBytes* random_;
  SessionUuidGenerator* uuids_;
  std::int64_t maximum_payload_;
  std::int64_t maximum_pending_;
  double post_tls_timeout_;

  enum class State {
    AwaitingStart,
    AwaitingAuthProof,
    AwaitingPairDecision,
    AwaitingDesktopConfirmation,
    Accepted,
    Closed,
  };

  State state_ = State::AwaitingStart;
  double deadline_ = 0.0;
  AuthenticationContext auth_context_;
  PairingContext pairing_context_;
  std::optional<SessionAcceptance> acceptance_;
};

}  // namespace rivet
