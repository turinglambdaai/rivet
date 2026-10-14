#include "rivet/device_session.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <utility>

#include "rivet/detail/sha256.hpp"

namespace rivet {
namespace {

constexpr std::array<std::uint8_t, 4> kSessionMagic{'R', 'V', 'D', '1'};

enum class SessionMessageType : std::uint8_t {
  Authenticate = 1,
  AuthChallenge = 2,
  AuthProof = 3,
  PairStart = 4,
  PairChallenge = 5,
  PairDecision = 6,
  Accept = 7,
  Paired = 8,
  Reject = 9,
};

constexpr char const* kRejectAuthenticationFailed = "authentication_failed";
constexpr char const* kRejectPairingUnavailable = "pairing_unavailable";
constexpr char const* kRejectPairingRejected = "pairing_rejected";
constexpr char const* kRejectPairingExpired = "pairing_expired";
constexpr char const* kRejectServerBusy = "server_busy";
constexpr char const* kRejectInternalError = "internal_error";

SessionMessageType session_message_type(SessionMessage const& message) {
  switch (message.index()) {
    case 0: return SessionMessageType::Authenticate;
    case 1: return SessionMessageType::AuthChallenge;
    case 2: return SessionMessageType::AuthProof;
    case 3: return SessionMessageType::PairStart;
    case 4: return SessionMessageType::PairChallenge;
    case 5: return SessionMessageType::PairDecision;
    case 6: return SessionMessageType::Accept;
    case 7: return SessionMessageType::Paired;
    default: return SessionMessageType::Reject;
  }
}

void append_bytes(Bytes& out, Bytes const& value) {
  out.insert(out.end(), value.begin(), value.end());
}

void append_u16_le(Bytes& out, std::uint16_t value) {
  out.push_back(static_cast<std::uint8_t>(value & 0xffu));
  out.push_back(static_cast<std::uint8_t>(value >> 8));
}

Bytes session_uuid_bytes(SessionUuid const& id) {
  return Bytes(id.begin(), id.end());
}

SessionUuid session_uuid_from(Bytes const& bytes) {
  if (bytes.size() != kSessionUuidSize) {
    throw std::runtime_error("invalid Rivet device session uuid");
  }
  SessionUuid id;
  std::copy(bytes.begin(), bytes.end(), id.begin());
  return id;
}

void require_bytes(Bytes const& value, std::size_t size) {
  if (value.size() != size) {
    throw std::runtime_error("invalid Rivet device session field");
  }
}

void require_api_name(std::string const& name) {
  if (!valid_device_api_name(name)) {
    throw std::runtime_error("invalid Rivet device session field");
  }
}

void require_limits(std::int64_t maximum_payload,
                    std::int64_t maximum_pending) {
  if (maximum_payload <= 0 ||
      maximum_payload > kSessionDefaultMaximumPayload ||
      maximum_pending <= 0 ||
      maximum_pending > kSessionDefaultMaximumPending) {
    throw std::runtime_error("invalid Rivet device session field");
  }
}

void require_canonical_scopes(std::vector<std::string> const& names) {
  if (!valid_scope_names(names)) {
    throw std::runtime_error("invalid Rivet device session field");
  }
  if (!std::is_sorted(names.begin(), names.end())) {
    throw std::runtime_error("invalid Rivet device session field");
  }
}

Value require_list(Value const& value) {
  if (!std::holds_alternative<Value::List>(value.data)) {
    throw std::runtime_error("malformed Rivet device session payload");
  }
  return value;
}

std::string require_string(Value const& value) {
  if (auto const* text = std::get_if<std::string>(&value.data)) {
    return *text;
  }
  throw std::runtime_error("malformed Rivet device session payload");
}

Bytes require_bytes_value(Value const& value) {
  if (auto const* bytes = std::get_if<Bytes>(&value.data)) {
    return *bytes;
  }
  throw std::runtime_error("malformed Rivet device session payload");
}

std::int64_t require_int64(Value const& value) {
  if (auto const* number = std::get_if<std::int64_t>(&value.data)) {
    return *number;
  }
  throw std::runtime_error("malformed Rivet device session payload");
}

std::vector<std::string> require_scope_list(Value const& value) {
  auto const list = require_list(value);
  auto const& items = std::get<Value::List>(list.data);
  std::vector<std::string> names;
  names.reserve(items.size());
  for (auto const& item : items) {
    names.push_back(require_string(item));
  }
  require_canonical_scopes(names);
  return names;
}

std::pair<std::int64_t, std::int64_t> require_limits_value(Value const& payload,
                                                           Value const& pending) {
  std::int64_t payload_value = require_int64(payload);
  std::int64_t pending_value = require_int64(pending);
  require_limits(payload_value, pending_value);
  return {payload_value, pending_value};
}

void append_length_prefixed(Bytes const& value, Bytes& out) {
  std::uint32_t length = static_cast<std::uint32_t>(value.size());
  out.push_back(static_cast<std::uint8_t>(length >> 24));
  out.push_back(static_cast<std::uint8_t>(length >> 16));
  out.push_back(static_cast<std::uint8_t>(length >> 8));
  out.push_back(static_cast<std::uint8_t>(length));
  append_bytes(out, value);
}

Bytes pairing_transcript(std::string const& domain,
                         std::string const& application_id,
                         Bytes const& server_fingerprint,
                         Bytes const& first_nonce, Bytes const& second_nonce) {
  Bytes transcript(domain.begin(), domain.end());
  append_length_prefixed(Bytes(application_id.begin(), application_id.end()),
                         transcript);
  append_length_prefixed(server_fingerprint, transcript);
  append_length_prefixed(first_nonce, transcript);
  append_length_prefixed(second_nonce, transcript);
  return transcript;
}

}  // namespace

std::string session_reject_code_string(SessionRejectCode code) {
  switch (code) {
    case SessionRejectCode::AuthenticationFailed: return kRejectAuthenticationFailed;
    case SessionRejectCode::PairingUnavailable: return kRejectPairingUnavailable;
    case SessionRejectCode::PairingRejected: return kRejectPairingRejected;
    case SessionRejectCode::PairingExpired: return kRejectPairingExpired;
    case SessionRejectCode::ServerBusy: return kRejectServerBusy;
    case SessionRejectCode::InternalError: return kRejectInternalError;
  }
  throw std::runtime_error("unknown Rivet device session reject code");
}

std::optional<SessionRejectCode> session_reject_code_from_string(
    std::string const& code) {
  if (code == kRejectAuthenticationFailed) {
    return SessionRejectCode::AuthenticationFailed;
  }
  if (code == kRejectPairingUnavailable) {
    return SessionRejectCode::PairingUnavailable;
  }
  if (code == kRejectPairingRejected) {
    return SessionRejectCode::PairingRejected;
  }
  if (code == kRejectPairingExpired) {
    return SessionRejectCode::PairingExpired;
  }
  if (code == kRejectServerBusy) {
    return SessionRejectCode::ServerBusy;
  }
  if (code == kRejectInternalError) {
    return SessionRejectCode::InternalError;
  }
  return std::nullopt;
}

bool valid_device_api_name(std::string const& name) {
  if (name.empty() || name.size() > 128) {
    return false;
  }
  for (char character : name) {
    unsigned char c = static_cast<unsigned char>(character);
    bool alphanumeric = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9');
    if (!alphanumeric && c != '.' && c != '-' && c != '_') {
      return false;
    }
  }
  return true;
}

bool valid_device_display_name(std::string const& name) {
  if (name.empty() || name.size() > 128) {
    return false;
  }
  std::size_t begin = 0;
  std::size_t end = name.size();
  auto is_space = [](unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' ||
           c == '\f';
  };
  while (begin < end && is_space(static_cast<unsigned char>(name[begin]))) {
    ++begin;
  }
  while (end > begin && is_space(static_cast<unsigned char>(name[end - 1]))) {
    --end;
  }
  if (begin != 0 || end != name.size()) {
    return false;
  }
  for (char character : name) {
    unsigned char c = static_cast<unsigned char>(character);
    if (c < 0x20 || c == 0x7f) {
      return false;
    }
  }
  return true;
}

bool valid_scope_names(std::vector<std::string> const& names) {
  if (names.size() > kSessionMaximumScopeCount) {
    return false;
  }
  for (std::size_t i = 0; i < names.size(); ++i) {
    if (!valid_device_api_name(names[i])) {
      return false;
    }
    for (std::size_t j = 0; j < i; ++j) {
      if (names[i] == names[j]) {
        return false;
      }
    }
  }
  return true;
}

std::vector<std::string> canonical_scope_names(std::vector<std::string> names) {
  std::sort(names.begin(), names.end());
  names.erase(std::unique(names.begin(), names.end()), names.end());
  return names;
}

Bytes session_authentication_proof(Bytes const& credential,
                                   std::string const& application_id,
                                   Bytes const& server_fingerprint,
                                   SessionUuid const& device_id,
                                   Bytes const& client_nonce,
                                   Bytes const& server_nonce) {
  if (credential.size() != kSessionCredentialSize ||
      !valid_device_api_name(application_id) ||
      server_fingerprint.size() != kSessionFingerprintSize ||
      client_nonce.size() != kSessionNonceSize ||
      server_nonce.size() != kSessionNonceSize) {
    throw std::runtime_error("invalid Rivet device session field");
  }
  // "rivet-device-auth-v1" || LP(app) || LP(fingerprint) || LP(device-id) ||
  // LP(client-nonce) || LP(server-nonce); transcript lengths are big-endian.
  Bytes transcript{'r', 'i', 'v', 'e', 't', '-', 'd', 'e', 'v', 'i', 'c',
                 'e', '-', 'a', 'u', 't', 'h', '-', 'v', '1'};
  append_length_prefixed(
      Bytes(application_id.begin(), application_id.end()), transcript);
  append_length_prefixed(server_fingerprint, transcript);
  append_length_prefixed(session_uuid_bytes(device_id), transcript);
  append_length_prefixed(client_nonce, transcript);
  append_length_prefixed(server_nonce, transcript);
  return detail::hmac_sha256(credential, transcript);
}

std::string session_pairing_code(std::string const& application_id,
                                 Bytes const& server_fingerprint,
                                 Bytes const& client_nonce,
                                 Bytes const& server_nonce) {
  if (!valid_device_api_name(application_id) ||
      server_fingerprint.size() != kSessionFingerprintSize ||
      client_nonce.size() != kSessionNonceSize ||
      server_nonce.size() != kSessionNonceSize) {
    throw std::runtime_error("invalid Rivet device session field");
  }
  Bytes transcript = pairing_transcript("rivet-device-pairing-v1",
                                        application_id, server_fingerprint,
                                        client_nonce, server_nonce);
  Bytes digest = detail::sha256(transcript);
  std::uint32_t prefix = (static_cast<std::uint32_t>(digest[0]) << 24) |
                         (static_cast<std::uint32_t>(digest[1]) << 16) |
                         (static_cast<std::uint32_t>(digest[2]) << 8) |
                         static_cast<std::uint32_t>(digest[3]);
  char buffer[7];
  std::snprintf(buffer, sizeof(buffer), "%06u",
                static_cast<unsigned>(prefix % 1000000u));
  return std::string(buffer);
}

Bytes encode_session_record(SessionMessage const& message) {
  Value::List fields;
  switch (message.index()) {
    case 0: {
      auto const& authenticate = std::get<SessionAuthenticate>(message);
      require_api_name(authenticate.application_id);
      require_bytes(authenticate.client_nonce, kSessionNonceSize);
      fields.emplace_back(authenticate.application_id);
      fields.emplace_back(session_uuid_bytes(authenticate.device_id));
      fields.emplace_back(authenticate.client_nonce);
      break;
    }
    case 1: {
      auto const& challenge = std::get<SessionAuthChallenge>(message);
      require_bytes(challenge.server_nonce, kSessionNonceSize);
      fields.emplace_back(challenge.server_nonce);
      break;
    }
    case 2: {
      auto const& proof = std::get<SessionAuthProof>(message);
      require_bytes(proof.proof, kSessionCredentialSize);
      fields.emplace_back(proof.proof);
      break;
    }
    case 3: {
      auto const& start = std::get<SessionPairStart>(message);
      require_api_name(start.application_id);
      if (!valid_device_display_name(start.device_name)) {
        throw std::runtime_error("invalid Rivet device session field");
      }
      require_bytes(start.client_nonce, kSessionNonceSize);
      fields.emplace_back(start.application_id);
      fields.emplace_back(session_uuid_bytes(start.window_id));
      fields.emplace_back(start.device_name);
      fields.emplace_back(start.client_nonce);
      break;
    }
    case 4: {
      auto const& challenge = std::get<SessionPairChallenge>(message);
      require_bytes(challenge.server_nonce, kSessionNonceSize);
      fields.emplace_back(session_uuid_bytes(challenge.attempt_id));
      fields.emplace_back(challenge.server_nonce);
      break;
    }
    case 5: {
      auto const& decision = std::get<SessionPairDecision>(message);
      fields.emplace_back(session_uuid_bytes(decision.attempt_id));
      fields.emplace_back(decision.confirmed);
      break;
    }
    case 6: {
      auto const& accept = std::get<SessionAccept>(message);
      require_limits(accept.maximum_payload, accept.maximum_pending);
      require_canonical_scopes(accept.scope_names);
      fields.emplace_back(session_uuid_bytes(accept.session_id));
      fields.emplace_back(Value::List(accept.scope_names.begin(),
                                      accept.scope_names.end()));
      fields.emplace_back(accept.maximum_payload);
      fields.emplace_back(accept.maximum_pending);
      break;
    }
    case 7: {
      auto const& paired = std::get<SessionPaired>(message);
      require_bytes(paired.credential, kSessionCredentialSize);
      require_limits(paired.maximum_payload, paired.maximum_pending);
      require_canonical_scopes(paired.scope_names);
      fields.emplace_back(session_uuid_bytes(paired.device_id));
      fields.emplace_back(paired.credential);
      fields.emplace_back(session_uuid_bytes(paired.session_id));
      fields.emplace_back(Value::List(paired.scope_names.begin(),
                                      paired.scope_names.end()));
      fields.emplace_back(paired.maximum_payload);
      fields.emplace_back(paired.maximum_pending);
      break;
    }
    default: {
      auto const& reject = std::get<SessionReject>(message);
      fields.emplace_back(session_reject_code_string(reject.code));
      break;
    }
  }

  Bytes payload = encode_value(Value{std::move(fields)});
  if (payload.size() > kSessionMaximumPayloadSize) {
    throw std::length_error("Rivet device session record exceeds its size limit");
  }

  Bytes record;
  append_bytes(record, Bytes(kSessionMagic.begin(), kSessionMagic.end()));
  record.push_back(kSessionVersion);
  record.push_back(static_cast<std::uint8_t>(session_message_type(message)));
  append_u16_le(record, static_cast<std::uint16_t>(payload.size()));
  append_bytes(record, payload);
  return record;
}

namespace {

SessionMessage message_from_fields(SessionMessageType type, Value const& payload) {
  auto const list = require_list(payload);
  auto const& fields = std::get<Value::List>(list.data);
  switch (type) {
    case SessionMessageType::Authenticate: {
      if (fields.size() != 3) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      std::string application_id = require_string(fields[0]);
      require_api_name(application_id);
      Bytes client_nonce = require_bytes_value(fields[2]);
      require_bytes(client_nonce, kSessionNonceSize);
      return SessionAuthenticate{application_id,
                                 session_uuid_from(require_bytes_value(fields[1])),
                                 client_nonce};
    }
    case SessionMessageType::AuthChallenge: {
      if (fields.size() != 1) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      Bytes server_nonce = require_bytes_value(fields[0]);
      require_bytes(server_nonce, kSessionNonceSize);
      return SessionAuthChallenge{std::move(server_nonce)};
    }
    case SessionMessageType::AuthProof: {
      if (fields.size() != 1) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      Bytes proof = require_bytes_value(fields[0]);
      require_bytes(proof, kSessionCredentialSize);
      return SessionAuthProof{std::move(proof)};
    }
    case SessionMessageType::PairStart: {
      if (fields.size() != 4) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      std::string application_id = require_string(fields[0]);
      require_api_name(application_id);
      std::string device_name = require_string(fields[2]);
      if (!valid_device_display_name(device_name)) {
        throw std::runtime_error("invalid Rivet device session field");
      }
      Bytes client_nonce = require_bytes_value(fields[3]);
      require_bytes(client_nonce, kSessionNonceSize);
      return SessionPairStart{application_id,
                              session_uuid_from(require_bytes_value(fields[1])),
                              std::move(device_name), std::move(client_nonce)};
    }
    case SessionMessageType::PairChallenge: {
      if (fields.size() != 2) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      Bytes server_nonce = require_bytes_value(fields[1]);
      require_bytes(server_nonce, kSessionNonceSize);
      return SessionPairChallenge{
          session_uuid_from(require_bytes_value(fields[0])),
          std::move(server_nonce)};
    }
    case SessionMessageType::PairDecision: {
      if (fields.size() != 2) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      auto const* confirmed = std::get_if<bool>(&fields[1].data);
      if (confirmed == nullptr) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      return SessionPairDecision{
          session_uuid_from(require_bytes_value(fields[0])), *confirmed};
    }
    case SessionMessageType::Accept: {
      if (fields.size() != 4) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      auto limits = require_limits_value(fields[2], fields[3]);
      return SessionAccept{session_uuid_from(require_bytes_value(fields[0])),
                           require_scope_list(fields[1]), limits.first,
                           limits.second};
    }
    case SessionMessageType::Paired: {
      if (fields.size() != 6) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      Bytes credential = require_bytes_value(fields[1]);
      require_bytes(credential, kSessionCredentialSize);
      auto limits = require_limits_value(fields[4], fields[5]);
      return SessionPaired{session_uuid_from(require_bytes_value(fields[0])),
                           std::move(credential),
                           session_uuid_from(require_bytes_value(fields[2])),
                           require_scope_list(fields[3]), limits.first,
                           limits.second};
    }
    case SessionMessageType::Reject: {
      if (fields.size() != 1) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      auto code = session_reject_code_from_string(require_string(fields[0]));
      if (!code) {
        throw std::runtime_error("malformed Rivet device session payload");
      }
      return SessionReject{*code};
    }
  }
  throw std::runtime_error("unknown Rivet device session message type");
}

SessionMessageType decode_message_type(std::uint8_t raw) {
  switch (raw) {
    case 1: return SessionMessageType::Authenticate;
    case 2: return SessionMessageType::AuthChallenge;
    case 3: return SessionMessageType::AuthProof;
    case 4: return SessionMessageType::PairStart;
    case 5: return SessionMessageType::PairChallenge;
    case 6: return SessionMessageType::PairDecision;
    case 7: return SessionMessageType::Accept;
    case 8: return SessionMessageType::Paired;
    case 9: return SessionMessageType::Reject;
    default: throw std::runtime_error("unknown Rivet device session message type");
  }
}

}  // namespace

SessionMessage decode_session_record(Bytes const& record) {
  if (record.size() < 8) {
    throw std::runtime_error("truncated Rivet device session record");
  }
  if (!std::equal(kSessionMagic.begin(), kSessionMagic.end(), record.begin())) {
    throw std::runtime_error("invalid Rivet device session magic");
  }
  if (record[4] != kSessionVersion) {
    throw std::runtime_error("unsupported Rivet device session version");
  }
  SessionMessageType type = decode_message_type(record[5]);
  std::size_t payload_length =
      static_cast<std::size_t>(record[6]) |
      (static_cast<std::size_t>(record[7]) << 8);
  if (payload_length > kSessionMaximumPayloadSize) {
    throw std::length_error("Rivet device session record exceeds its size limit");
  }
  if (record.size() < 8 + payload_length) {
    throw std::runtime_error("truncated Rivet device session record");
  }
  if (record.size() != 8 + payload_length) {
    throw std::runtime_error("malformed Rivet device session payload");
  }
  Value payload = decode_value(
      Bytes(record.begin() + 8, record.begin() + 8 + payload_length));
  return message_from_fields(type, payload);
}

std::vector<SessionMessage> SessionRecordDecoder::append(Bytes const& bytes) {
  if (failed_) {
    throw std::runtime_error("Rivet device session decoder is closed after a protocol failure");
  }
  std::vector<SessionMessage> messages;
  std::size_t offset = 0;
  try {
    while (offset < bytes.size()) {
      std::size_t target = expected_record_length_.value_or(8);
      std::size_t needed = target - buffer_.size();
      std::size_t available = bytes.size() - offset;
      std::size_t count = std::min(needed, available);
      buffer_.insert(buffer_.end(), bytes.begin() + offset,
                     bytes.begin() + offset + count);
      offset += count;

      if (!expected_record_length_ && buffer_.size() == 8) {
        validate_header();
      }
      if (expected_record_length_ && buffer_.size() == *expected_record_length_) {
        messages.push_back(decode_session_record(buffer_));
        buffer_.clear();
        expected_record_length_.reset();
      }
    }
    return messages;
  } catch (...) {
    failed_ = true;
    buffer_.clear();
    expected_record_length_.reset();
    throw;
  }
}

void SessionRecordDecoder::finish() {
  if (failed_) {
    throw std::runtime_error("Rivet device session decoder is closed after a protocol failure");
  }
  if (!buffer_.empty()) {
    failed_ = true;
    buffer_.clear();
    expected_record_length_.reset();
    throw std::runtime_error("truncated Rivet device session record");
  }
}

void SessionRecordDecoder::validate_header() {
  if (!std::equal(kSessionMagic.begin(), kSessionMagic.end(), buffer_.begin())) {
    throw std::runtime_error("invalid Rivet device session magic");
  }
  if (buffer_[4] != kSessionVersion) {
    throw std::runtime_error("unsupported Rivet device session version");
  }
  decode_message_type(buffer_[5]);
  std::size_t payload_length =
      static_cast<std::size_t>(buffer_[6]) |
      (static_cast<std::size_t>(buffer_[7]) << 8);
  if (payload_length > kSessionMaximumPayloadSize) {
    throw std::length_error("Rivet device session record exceeds its size limit");
  }
  expected_record_length_ = 8 + payload_length;
}

SessionRejectCode session_reject_code_for(SessionPairingError error) {
  switch (error) {
    case SessionPairingError::WindowExpired:
      return SessionRejectCode::PairingExpired;
    case SessionPairingError::WindowUnavailable:
    case SessionPairingError::AttemptUnavailable:
      return SessionRejectCode::PairingUnavailable;
    case SessionPairingError::WindowAlreadyOpen:
    case SessionPairingError::AttemptInProgress:
      return SessionRejectCode::ServerBusy;
    case SessionPairingError::InvalidDeviceName:
      return SessionRejectCode::PairingRejected;
    case SessionPairingError::AuthenticationFailed:
      return SessionRejectCode::InternalError;
  }
  return SessionRejectCode::InternalError;
}

DeviceSessionServer::DeviceSessionServer(
    std::string application_id, Bytes server_fingerprint,
    SessionPairingStore* store, SessionPairingCoordinator* coordinator,
    SessionRandomBytes* random, SessionUuidGenerator* uuids,
    std::int64_t maximum_payload, std::int64_t maximum_pending,
    double post_tls_timeout, double started_at)
    : application_id_(std::move(application_id)),
      server_fingerprint_(std::move(server_fingerprint)),
      store_(store),
      coordinator_(coordinator),
      random_(random),
      uuids_(uuids),
      maximum_payload_(maximum_payload),
      maximum_pending_(maximum_pending),
      post_tls_timeout_(post_tls_timeout) {
  if (!valid_device_api_name(application_id_) ||
      server_fingerprint_.size() != kSessionFingerprintSize ||
      maximum_payload_ <= 0 ||
      maximum_payload_ > kSessionDefaultMaximumPayload ||
      maximum_pending_ <= 0 ||
      maximum_pending_ > kSessionDefaultMaximumPending ||
      !(post_tls_timeout_ > 0.0)) {
    throw std::runtime_error("invalid Rivet device session field");
  }
  deadline_ = started_at + post_tls_timeout_;
}

bool DeviceSessionServer::expired(double now) const {
  switch (state_) {
    case State::AwaitingStart:
    case State::AwaitingAuthProof:
      return now >= deadline_;
    case State::AwaitingPairDecision:
    case State::AwaitingDesktopConfirmation:
      return now >= pairing_context_.expires_at;
    case State::Accepted:
    case State::Closed:
      return false;
  }
  return false;
}

std::vector<SessionServerAction> DeviceSessionServer::receive(
    SessionMessage const& message, double now) {
  // Mirror the Swift server: expiry is evaluated before every receive, and a
  // pairing expiry supersedes the per-message deadline.
  std::vector<SessionServerAction> timeout_actions;
  if (expired(now)) {
    timeout_actions = expire(now);
    if (!timeout_actions.empty()) {
      return timeout_actions;
    }
  }

  switch (state_) {
    case State::AwaitingStart: {
      if (auto const* authenticate = std::get_if<SessionAuthenticate>(&message)) {
        return begin_authentication(*authenticate, now);
      }
      if (auto const* start = std::get_if<SessionPairStart>(&message)) {
        return begin_pairing(*start, now);
      }
      state_ = State::Closed;
      throw std::runtime_error("Rivet device session protocol violation");
    }
    case State::AwaitingAuthProof: {
      auto const* proof = std::get_if<SessionAuthProof>(&message);
      if (proof == nullptr) {
        state_ = State::Closed;
        throw std::runtime_error("Rivet device session protocol violation");
      }
      return finish_authentication(proof->proof, now);
    }
    case State::AwaitingPairDecision: {
      auto const* decision = std::get_if<SessionPairDecision>(&message);
      if (decision == nullptr) {
        state_ = State::Closed;
        throw std::runtime_error("Rivet device session protocol violation");
      }
      return handle_pair_decision(*decision, now);
    }
    case State::AwaitingDesktopConfirmation:
    case State::Accepted:
      state_ = State::Closed;
      throw std::runtime_error("Rivet device session protocol violation");
    case State::Closed:
      throw std::runtime_error("Rivet device session is closed");
  }
  throw std::runtime_error("Rivet device session is closed");
}

std::vector<SessionServerAction> DeviceSessionServer::begin_authentication(
    SessionAuthenticate const& authenticate, double now) {
  Bytes server_nonce;
  Bytes dummy_credential;
  try {
    server_nonce = random_->random_bytes(kSessionNonceSize);
    dummy_credential = random_->random_bytes(kSessionCredentialSize);
  } catch (...) {
    return close_with_reject(SessionRejectCode::InternalError);
  }
  if (server_nonce.size() != kSessionNonceSize ||
      dummy_credential.size() != kSessionCredentialSize) {
    return close_with_reject(SessionRejectCode::InternalError);
  }

  std::optional<SessionStoredPairing> candidate;
  try {
    candidate = store_->load(authenticate.device_id);
  } catch (...) {
    candidate.reset();
  }
  if (candidate) {
    auto const& pairing = *candidate;
    bool usable =
        pairing.device.id == authenticate.device_id &&
        pairing.device.application_id == authenticate.application_id &&
        authenticate.application_id == application_id_ &&
        detail::constant_time_equal(pairing.device.server_fingerprint,
                                    server_fingerprint_) &&
        pairing.device.server_fingerprint.size() == kSessionFingerprintSize &&
        pairing.credential.size() == kSessionCredentialSize &&
        valid_scope_names(pairing.device.scope_names);
    if (!usable) {
      candidate.reset();
    }
  }

  auth_context_ = AuthenticationContext{
      authenticate.application_id, authenticate.device_id,
      authenticate.client_nonce,   server_nonce,
      candidate ? candidate->credential : dummy_credential,
      std::move(candidate)};
  state_ = State::AwaitingAuthProof;
  deadline_ = now + post_tls_timeout_;
  return {SessionServerAction{SessionServerAction::Send{
      SessionAuthChallenge{std::move(server_nonce)}}}};
}

std::vector<SessionServerAction> DeviceSessionServer::finish_authentication(
    Bytes const& proof, double now) {
  Bytes expected;
  try {
    expected = session_authentication_proof(
        auth_context_.credential, auth_context_.application_id,
        server_fingerprint_, auth_context_.device_id,
        auth_context_.client_nonce, auth_context_.server_nonce);
  } catch (...) {
    return close_with_reject(SessionRejectCode::AuthenticationFailed);
  }
  if (!detail::constant_time_equal(expected, proof) ||
      !auth_context_.candidate) {
    return close_with_reject(SessionRejectCode::AuthenticationFailed);
  }

  SessionPairedDevice device = auth_context_.candidate->device;
  device.last_used_at = std::max(now, device.last_used_at);
  try {
    store_->save(SessionStoredPairing{device, auth_context_.candidate->credential});
  } catch (...) {
    return close_with_reject(SessionRejectCode::InternalError);
  }

  SessionAcceptance acceptance = make_acceptance(device);
  acceptance_ = acceptance;
  state_ = State::Accepted;
  return {
      SessionServerAction{SessionServerAction::Send{SessionAccept{
          acceptance.session_id, acceptance.scope_names,
          acceptance.maximum_payload, acceptance.maximum_pending}}},
      SessionServerAction{SessionServerAction::Accepted{acceptance}}};
}

std::vector<SessionServerAction> DeviceSessionServer::begin_pairing(
    SessionPairStart const& start, double now) {
  if (start.application_id != application_id_) {
    return close_with_reject(SessionRejectCode::PairingUnavailable);
  }
  SessionPairingChallenge challenge;
  try {
    challenge = coordinator_->begin_attempt(start.window_id, start.device_name,
                                            start.client_nonce, now);
  } catch (SessionPairingError const& error) {
    return close_with_reject(session_reject_code_for(error));
  } catch (...) {
    return close_with_reject(SessionRejectCode::InternalError);
  }
  pairing_context_ = PairingContext{start.window_id, challenge.attempt_id,
                                    challenge.expires_at};
  state_ = State::AwaitingPairDecision;
  deadline_ = now + post_tls_timeout_;
  return {
      SessionServerAction{SessionServerAction::Send{SessionPairChallenge{
          challenge.attempt_id, challenge.server_nonce}}},
      SessionServerAction{SessionServerAction::ShowPairingCode{
          challenge.attempt_id, challenge.verification_code,
          challenge.expires_at}}};
}

std::vector<SessionServerAction> DeviceSessionServer::handle_pair_decision(
    SessionPairDecision const& decision, double now) {
  if (!(decision.attempt_id == pairing_context_.attempt_id) ||
      !decision.confirmed) {
    try {
      coordinator_->fail_attempt(pairing_context_.window_id,
                                 pairing_context_.attempt_id, now);
    } catch (...) {
      // The pairing outcome is already decided; storage failures only affect
      // the window bookkeeping.
    }
    return close_with_reject(SessionRejectCode::PairingRejected);
  }
  std::optional<SessionPairingResult> result;
  try {
    result = coordinator_->confirm_on_device(
        pairing_context_.window_id, pairing_context_.attempt_id, now);
  } catch (SessionPairingError const& error) {
    try {
      coordinator_->abandon_attempt(pairing_context_.window_id,
                                    pairing_context_.attempt_id, now);
    } catch (...) {
    }
    return close_with_reject(session_reject_code_for(error));
  } catch (...) {
    try {
      coordinator_->abandon_attempt(pairing_context_.window_id,
                                    pairing_context_.attempt_id, now);
    } catch (...) {
    }
    return close_with_reject(SessionRejectCode::InternalError);
  }
  if (!result) {
    state_ = State::AwaitingDesktopConfirmation;
    return {};
  }
  return finish_pairing(std::move(*result));
}

std::vector<SessionServerAction> DeviceSessionServer::confirm_pairing_on_desktop(
    std::vector<std::string> const& granted_scope_names, double now) {
  std::vector<SessionServerAction> timeout_actions = expire(now);
  if (!timeout_actions.empty()) {
    return timeout_actions;
  }
  switch (state_) {
    case State::AwaitingPairDecision:
    case State::AwaitingDesktopConfirmation:
      break;
    case State::Closed:
      throw std::runtime_error("Rivet device session is closed");
    default:
      throw std::runtime_error("Rivet device pairing is not active");
  }

  std::vector<std::string> canonical =
      canonical_scope_names(granted_scope_names);
  if (!valid_scope_names(canonical)) {
    try {
      coordinator_->fail_attempt(pairing_context_.window_id,
                                 pairing_context_.attempt_id, now);
    } catch (...) {
    }
    return close_with_reject(SessionRejectCode::PairingRejected);
  }
  std::optional<SessionPairingResult> result;
  try {
    result = coordinator_->confirm_on_desktop(
        pairing_context_.window_id, pairing_context_.attempt_id, canonical,
        now);
  } catch (SessionPairingError const& error) {
    try {
      coordinator_->abandon_attempt(pairing_context_.window_id,
                                    pairing_context_.attempt_id, now);
    } catch (...) {
    }
    return close_with_reject(session_reject_code_for(error));
  } catch (...) {
    try {
      coordinator_->abandon_attempt(pairing_context_.window_id,
                                    pairing_context_.attempt_id, now);
    } catch (...) {
    }
    return close_with_reject(SessionRejectCode::InternalError);
  }
  if (!result) {
    return {};
  }
  return finish_pairing(std::move(*result));
}

std::vector<SessionServerAction> DeviceSessionServer::reject_pairing_on_desktop(
    double now) {
  switch (state_) {
    case State::AwaitingPairDecision:
    case State::AwaitingDesktopConfirmation:
      break;
    case State::Closed:
      throw std::runtime_error("Rivet device session is closed");
    default:
      throw std::runtime_error("Rivet device pairing is not active");
  }
  try {
    coordinator_->fail_attempt(pairing_context_.window_id,
                               pairing_context_.attempt_id, now);
  } catch (...) {
    return close_with_reject(SessionRejectCode::InternalError);
  }
  return close_with_reject(SessionRejectCode::PairingRejected);
}

std::vector<SessionServerAction> DeviceSessionServer::expire(double now) {
  switch (state_) {
    case State::AwaitingStart:
    case State::AwaitingAuthProof:
      if (now >= deadline_) {
        state_ = State::Closed;
        return {SessionServerAction{SessionServerAction::Close{}}};
      }
      return {};
    case State::AwaitingPairDecision:
      if (now >= pairing_context_.expires_at) {
        try {
          coordinator_->expire_window(now);
        } catch (...) {
        }
        return close_with_reject(SessionRejectCode::PairingExpired);
      }
      if (now >= deadline_) {
        try {
          coordinator_->abandon_attempt(pairing_context_.window_id,
                                        pairing_context_.attempt_id, now);
        } catch (...) {
        }
        state_ = State::Closed;
        return {SessionServerAction{SessionServerAction::Close{}}};
      }
      return {};
    case State::AwaitingDesktopConfirmation:
      if (now >= pairing_context_.expires_at) {
        try {
          coordinator_->expire_window(now);
        } catch (...) {
        }
        return close_with_reject(SessionRejectCode::PairingExpired);
      }
      return {};
    case State::Accepted:
    case State::Closed:
      return {};
  }
  return {};
}

void DeviceSessionServer::disconnect(double now) {
  switch (state_) {
    case State::AwaitingPairDecision:
    case State::AwaitingDesktopConfirmation:
      try {
        coordinator_->abandon_attempt(pairing_context_.window_id,
                                      pairing_context_.attempt_id, now);
      } catch (...) {
      }
      break;
    default:
      break;
  }
  state_ = State::Closed;
}

SessionAcceptance DeviceSessionServer::make_acceptance(
    SessionPairedDevice const& device) {
  SessionAcceptance acceptance;
  acceptance.session_id = uuids_->next_uuid();
  acceptance.device_id = device.id;
  acceptance.application_id = device.application_id;
  acceptance.scope_names = canonical_scope_names(device.scope_names);
  acceptance.maximum_payload = maximum_payload_;
  acceptance.maximum_pending = maximum_pending_;
  return acceptance;
}

std::vector<SessionServerAction> DeviceSessionServer::finish_pairing(
    SessionPairingResult result) {
  SessionAcceptance acceptance = make_acceptance(result.device);
  acceptance_ = acceptance;
  state_ = State::Accepted;
  return {
      SessionServerAction{SessionServerAction::Send{SessionPaired{
          result.device.id, result.credential, acceptance.session_id,
          acceptance.scope_names, acceptance.maximum_payload,
          acceptance.maximum_pending}}},
      SessionServerAction{SessionServerAction::Accepted{acceptance}}};
}

std::vector<SessionServerAction> DeviceSessionServer::close_with_reject(
    SessionRejectCode code) {
  state_ = State::Closed;
  return {SessionServerAction{SessionServerAction::Send{SessionReject{code}}},
          SessionServerAction{SessionServerAction::Close{}}};
}

}  // namespace rivet
