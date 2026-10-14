#include "rivet/device_session.hpp"
#include "rivet/detail/sha256.hpp"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace rivet;

struct GoldenRecord {
  std::string kind;
  std::string name;
  std::string raw;
  Bytes bytes;
};

std::uint8_t hex_nibble(char value) {
  if (value >= '0' && value <= '9') return static_cast<std::uint8_t>(value - '0');
  if (value >= 'a' && value <= 'f') return static_cast<std::uint8_t>(10 + value - 'a');
  if (value >= 'A' && value <= 'F') return static_cast<std::uint8_t>(10 + value - 'A');
  throw std::runtime_error("invalid hex digit in device session fixture");
}

Bytes hex_bytes(std::string const& hex) {
  if (hex.size() % 2 != 0) {
    throw std::runtime_error("odd-length hex in device session fixture");
  }
  Bytes bytes;
  bytes.reserve(hex.size() / 2);
  for (std::size_t i = 0; i < hex.size(); i += 2) {
    bytes.push_back(static_cast<std::uint8_t>(
        (hex_nibble(hex[i]) << 4) | hex_nibble(hex[i + 1])));
  }
  return bytes;
}

std::vector<GoldenRecord> load_device_session_golden() {
  std::ifstream input("device-session-golden.txt");
  if (!input) throw std::runtime_error("cannot open device-session-golden.txt");
  std::vector<GoldenRecord> records;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    auto first = line.find('|');
    auto second = line.find('|', first + 1);
    if (first == std::string::npos || second == std::string::npos) {
      throw std::runtime_error("malformed device session fixture line");
    }
    std::string raw = line.substr(second + 1);
    records.push_back(GoldenRecord{line.substr(0, first),
                                   line.substr(first + 1, second - first - 1),
                                   raw, hex_bytes(raw)});
  }
  return records;
}

SessionUuid uuid_from_hex(std::string const& hex) {
  Bytes bytes = hex_bytes(hex);
  SessionUuid id;
  std::copy(bytes.begin(), bytes.end(), id.begin());
  return id;
}

constexpr char const* kApplicationID = "com.example.app";
constexpr char const* kDeviceID = "00112233445566778899aabbccddeeff";
constexpr char const* kWindowID = "102132435465768798a9bacbdcedfe0f";
constexpr char const* kAttemptID = "ffeeddccbbaa99887766554433221100";
constexpr char const* kSessionID = "0123456789abcdef0123456789abcdef";

Bytes nonce(std::uint8_t fill) {
  return Bytes(kSessionNonceSize, fill);
}

Bytes credential(std::uint8_t fill) {
  return Bytes(kSessionCredentialSize, fill);
}

Bytes fingerprint(std::uint8_t fill) {
  return Bytes(kSessionFingerprintSize, fill);
}

class FakeRandom final : public SessionRandomBytes {
 public:
  explicit FakeRandom(std::vector<Bytes> values) : values_(std::move(values)) {}

  Bytes random_bytes(std::size_t count) override {
    if (values_.empty()) {
      throw std::runtime_error("fake random exhausted");
    }
    Bytes value = std::move(values_.front());
    values_.erase(values_.begin());
    if (value.size() != count) {
      throw std::runtime_error("fake random size mismatch");
    }
    return value;
  }

 private:
  std::vector<Bytes> values_;
};

class FakeUuids final : public SessionUuidGenerator {
 public:
  explicit FakeUuids(std::vector<SessionUuid> values) : values_(std::move(values)) {}

  SessionUuid next_uuid() override {
    if (values_.empty()) {
      throw std::runtime_error("fake uuids exhausted");
    }
    SessionUuid value = values_.front();
    values_.erase(values_.begin());
    return value;
  }

 private:
  std::vector<SessionUuid> values_;
};

class FakeStore final : public SessionPairingStore {
 public:
  std::optional<SessionStoredPairing> load(
      SessionUuid const& device_id) override {
    auto match = stored.find(device_id);
    if (match == stored.end()) return std::nullopt;
    return match->second;
  }

  void save(SessionStoredPairing const& pairing) override {
    saved.push_back(pairing);
    stored[pairing.device.id] = pairing;
  }

  std::vector<SessionStoredPairing> saved;
  std::set<SessionUuid> keys() const {
    std::set<SessionUuid> keys;
    for (auto const& entry : stored) keys.insert(entry.first);
    return keys;
  }

 private:
  std::map<SessionUuid, SessionStoredPairing> stored;
};

class FakeCoordinator final : public SessionPairingCoordinator {
 public:
  SessionPairingChallenge begin_attempt(SessionUuid const& window_id,
                                        std::string const& device_name,
                                        Bytes const& client_nonce,
                                        double now) override {
    (void)window_id;
    (void)device_name;
    (void)client_nonce;
    (void)now;
    return SessionPairingChallenge{attempt_id, nonce(0x22), "222296",
                                   expires_at};
  }

  std::optional<SessionPairingResult> confirm_on_desktop(
      SessionUuid const&, SessionUuid const&,
      std::vector<std::string> const& granted_scope_names, double) override {
    if (!desktop_result) return std::nullopt;
    desktop_granted = granted_scope_names;
    desktop_confirmed = true;
    return desktop_result;
  }

  std::optional<SessionPairingResult> confirm_on_device(SessionUuid const&,
                                                        SessionUuid const&,
                                                        double) override {
    device_confirmed = true;
    if (desktop_confirmed) return desktop_result;
    return std::nullopt;
  }

  void fail_attempt(SessionUuid const&, SessionUuid const&, double) override {
    fail_attempts += 1;
  }

  void abandon_attempt(SessionUuid const&, SessionUuid const&, double) override {
    abandon_attempts += 1;
  }

  void expire_window(double) override { expire_windows += 1; }

  SessionUuid attempt_id = uuid_from_hex(kAttemptID);
  double expires_at = 300.0;
  std::optional<SessionPairingResult> desktop_result;
  std::vector<std::string> desktop_granted;
  bool device_confirmed = false;
  bool desktop_confirmed = false;
  int fail_attempts = 0;
  int abandon_attempts = 0;
  int expire_windows = 0;
};

SessionPairedDevice paired_device() {
  SessionPairedDevice device;
  device.id = uuid_from_hex(kDeviceID);
  device.application_id = kApplicationID;
  device.name = "Test Phone";
  device.scope_names = {"reader"};
  device.server_fingerprint = fingerprint(0x51);
  device.created_at = 100.0;
  device.last_used_at = 100.0;
  return device;
}

SessionStoredPairing stored_pairing() {
  return SessionStoredPairing{paired_device(), credential(0x63)};
}

SessionPairingResult pairing_result() {
  return SessionPairingResult{paired_device(), credential(0x33)};
}

struct ServerHarness {
  FakeStore store;
  FakeCoordinator coordinator;
  FakeRandom random{std::vector<Bytes>{nonce(0x22), credential(0x64)}};
  FakeUuids uuids{std::vector<SessionUuid>{uuid_from_hex(kSessionID)}};
  std::unique_ptr<DeviceSessionServer> server;

  ServerHarness() {
    server = std::make_unique<DeviceSessionServer>(
        kApplicationID, fingerprint(0x51), &store, &coordinator, &random,
        &uuids, kSessionDefaultMaximumPayload, kSessionDefaultMaximumPending,
        10.0, 100.0);
  }
};

SessionAccept const& as_accept(SessionServerAction const& action) {
  auto const* send = std::get_if<SessionServerAction::Send>(&action.action);
  assert(send != nullptr);
  auto const* accept = std::get_if<SessionAccept>(&send->message);
  assert(accept != nullptr);
  return *accept;
}

SessionReject const& as_reject(SessionServerAction const& action) {
  auto const* send = std::get_if<SessionServerAction::Send>(&action.action);
  assert(send != nullptr);
  auto const* reject = std::get_if<SessionReject>(&send->message);
  assert(reject != nullptr);
  return *reject;
}

template <typename T>
T const& payload_of(SessionMessage const& message) {
  auto const* value = std::get_if<T>(&message);
  assert(value != nullptr);
  return *value;
}

// ---------------------------------------------------------------------------
// Golden fixture vectors.

void test_golden_records_round_trip() {
  auto records = load_device_session_golden();
  bool saw_record = false;
  bool saw_proof = false;
  bool saw_code = false;
  for (auto const& record : records) {
    if (record.kind == "record") {
      saw_record = true;
      SessionMessage decoded = decode_session_record(record.bytes);
      Bytes encoded = encode_session_record(decoded);
      assert(encoded == record.bytes);
      // Every record also survives the incremental decoder, including when
      // it arrives one byte at a time.
      SessionRecordDecoder whole;
      auto messages = whole.append(record.bytes);
      whole.finish();
      assert(messages.size() == 1);
      SessionRecordDecoder byte_wise;
      std::vector<SessionMessage> streamed;
      for (std::uint8_t byte : record.bytes) {
        auto part = byte_wise.append(Bytes{byte});
        streamed.insert(streamed.end(), part.begin(), part.end());
      }
      byte_wise.finish();
      assert(streamed.size() == 1);
      assert(encode_session_record(streamed[0]) ==
             encode_session_record(messages[0]));

      // Two records delivered in one coalesced read both decode.
      SessionRecordDecoder coalesced;
      Bytes doubled = record.bytes;
      doubled.insert(doubled.end(), record.bytes.begin(), record.bytes.end());
      auto two = coalesced.append(doubled);
      coalesced.finish();
      assert(two.size() == 2);
    } else if (record.kind == "proof") {
      saw_proof = true;
      Bytes expected = session_authentication_proof(
          credential(0x33), kApplicationID, fingerprint(0x55),
          uuid_from_hex(kDeviceID), nonce(0x11), nonce(0x22));
      assert(expected == record.bytes);
    } else if (record.kind == "code") {
      saw_code = true;
      std::string code = session_pairing_code(
          kApplicationID, fingerprint(0x55), nonce(0x11), nonce(0x22));
      assert(code == record.raw);
    }
  }
  assert(saw_record);
  assert(saw_proof);
  assert(saw_code);
  std::cout << "device_session golden vectors: ok\n";
}

void test_decode_field_values() {
  auto records = load_device_session_golden();
  SessionMessage message;
  bool found = false;
  for (auto const& record : records) {
    if (record.name == "authenticate") {
      message = decode_session_record(record.bytes);
      found = true;
    }
  }
  assert(found);
  auto const& authenticate = payload_of<SessionAuthenticate>(message);
  assert(authenticate.application_id == kApplicationID);
  assert(authenticate.device_id == uuid_from_hex(kDeviceID));
  assert(authenticate.client_nonce == nonce(0x11));

  for (auto const& record : records) {
    if (record.name != "paired") continue;
    SessionMessage message = decode_session_record(record.bytes);
    auto const& paired = payload_of<SessionPaired>(message);
    assert(paired.device_id == uuid_from_hex(kDeviceID));
    assert(paired.credential == credential(0x33));
    assert(paired.scope_names ==
           std::vector<std::string>({"controller", "reader"}));
    assert(paired.maximum_payload == 524288);
    assert(paired.maximum_pending == 64);
  }

  for (auto const& record : records) {
    if (record.name != "reject") continue;
    SessionMessage message = decode_session_record(record.bytes);
    auto const& reject = payload_of<SessionReject>(message);
    assert(reject.code == SessionRejectCode::AuthenticationFailed);
    assert(session_reject_code_string(reject.code) == "authentication_failed");
  }
}

void test_decoder_rejects_malformed_streams() {
  bool threw = false;
  try {
    SessionRecordDecoder decoder;
    decoder.append(Bytes{0x52, 0x56, 0x44, 0x31, 0x01, 0x01, 0x00, 0x00, 0x00});
    decoder.finish();
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);

  threw = false;
  try {
    SessionRecordDecoder decoder;
    decoder.append(Bytes{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07});
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);

  // After a failure the decoder stays poisoned.
  threw = false;
  try {
    SessionRecordDecoder decoder;
    decoder.append(Bytes{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07});
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
}

// ---------------------------------------------------------------------------
// Server state machine.

void test_reconnect_authenticates_and_accepts() {
  ServerHarness harness;
  harness.store.save(stored_pairing());

  auto actions = harness.server->receive(
      SessionAuthenticate{kApplicationID, uuid_from_hex(kDeviceID), nonce(0x11)},
      101.0);
  assert(actions.size() == 1);
  auto const& challenge = payload_of<SessionAuthChallenge>(
      std::get<SessionServerAction::Send>(actions[0].action).message);
  assert(challenge.server_nonce == nonce(0x22));
  assert(harness.server->acceptance() == std::nullopt);

  Bytes proof = session_authentication_proof(
      credential(0x63), kApplicationID, fingerprint(0x51),
      uuid_from_hex(kDeviceID), nonce(0x11), nonce(0x22));
  actions = harness.server->receive(SessionAuthProof{proof}, 102.0);
  assert(actions.size() == 2);
  auto const& accept = as_accept(actions[0]);
  assert(accept.session_id == uuid_from_hex(kSessionID));
  assert(accept.scope_names == std::vector<std::string>({"reader"}));
  assert(accept.maximum_payload == kSessionDefaultMaximumPayload);
  assert(accept.maximum_pending == kSessionDefaultMaximumPending);
  assert(std::holds_alternative<SessionServerAction::Accepted>(actions[1].action));
  assert(harness.server->acceptance());
  assert(harness.server->acceptance()->device_id == uuid_from_hex(kDeviceID));
  assert(harness.store.saved.size() == 2);
  assert(harness.store.saved.back().device.last_used_at == 102.0);
  std::cout << "device_session reconnect: ok\n";
}

void test_reconnect_unknown_device_uses_dummy_credential() {
  ServerHarness harness;
  auto actions = harness.server->receive(
      SessionAuthenticate{kApplicationID, uuid_from_hex(kDeviceID), nonce(0x11)},
      0.0);
  assert(actions.size() == 1);
  // A fresh challenge is emitted even though the device is unknown, so the
  // record sequence cannot reveal which field failed.
  auto const& challenge = payload_of<SessionAuthChallenge>(
      std::get<SessionServerAction::Send>(actions[0].action).message);
  assert(challenge.server_nonce == nonce(0x22));

  Bytes wrong = session_authentication_proof(
      credential(0x00), kApplicationID, fingerprint(0x51),
      uuid_from_hex(kDeviceID), nonce(0x11), nonce(0x22));
  actions = harness.server->receive(SessionAuthProof{wrong}, 1.0);
  assert(actions.size() == 2);
  assert(as_reject(actions[0]).code == SessionRejectCode::AuthenticationFailed);
  assert(std::holds_alternative<SessionServerAction::Close>(actions[1].action));
  assert(harness.store.saved.empty());
  std::cout << "device_session unknown device: ok\n";
}

void test_reconnect_wrong_application_id_fails_closed() {
  ServerHarness harness;
  harness.store.save(stored_pairing());
  harness.server->receive(
      SessionAuthenticate{"com.example.other", uuid_from_hex(kDeviceID),
                          nonce(0x11)},
      0.0);
  Bytes proof = session_authentication_proof(
      credential(0x63), "com.example.other", fingerprint(0x51),
      uuid_from_hex(kDeviceID), nonce(0x11), nonce(0x22));
  auto actions = harness.server->receive(SessionAuthProof{proof}, 1.0);
  assert(as_reject(actions[0]).code == SessionRejectCode::AuthenticationFailed);
  std::cout << "device_session wrong app id: ok\n";
}

void test_pairing_completes_after_both_confirmations() {
  ServerHarness harness;
  harness.coordinator.desktop_result = pairing_result();

  auto actions = harness.server->receive(
      SessionPairStart{kApplicationID, uuid_from_hex(kWindowID), "Test Phone",
                       nonce(0x11)},
      0.0);
  assert(actions.size() == 2);
  auto const& challenge = payload_of<SessionPairChallenge>(
      std::get<SessionServerAction::Send>(actions[0].action).message);
  assert(challenge.attempt_id == uuid_from_hex(kAttemptID));
  assert(challenge.server_nonce == nonce(0x22));
  auto const& shown =
      std::get<SessionServerAction::ShowPairingCode>(actions[1].action);
  assert(shown.verification_code == "222296");
  assert(shown.expires_at == 300.0);
  assert(harness.server->acceptance() == std::nullopt);

  actions = harness.server->receive(
      SessionPairDecision{uuid_from_hex(kAttemptID), true}, 1.0);
  // The desktop has not confirmed yet, so no action is emitted.
  assert(actions.empty());
  assert(!harness.server->acceptance());

  actions = harness.server->confirm_pairing_on_desktop({"reader", "reader"},
                                                       2.0);
  assert(harness.coordinator.desktop_granted ==
         std::vector<std::string>({"reader"}));
  assert(actions.size() == 2);
  auto const& paired = payload_of<SessionPaired>(
      std::get<SessionServerAction::Send>(actions[0].action).message);
  assert(paired.device_id == uuid_from_hex(kDeviceID));
  assert(paired.credential == credential(0x33));
  assert(paired.session_id == uuid_from_hex(kSessionID));
  assert(std::holds_alternative<SessionServerAction::Accepted>(actions[1].action));
  std::cout << "device_session pairing: ok\n";
}

void test_pairing_rejects_declined_decision_and_unknown_attempts() {
  {
    ServerHarness harness;
    auto actions = harness.server->receive(
        SessionPairStart{kApplicationID, uuid_from_hex(kWindowID), "Test Phone",
                         nonce(0x11)},
        0.0);
    assert(actions.size() == 2);
    actions = harness.server->receive(
        SessionPairDecision{uuid_from_hex(kAttemptID), false}, 1.0);
    assert(as_reject(actions[0]).code == SessionRejectCode::PairingRejected);
    assert(harness.coordinator.fail_attempts == 1);
  }
  {
    ServerHarness harness;
    harness.server->receive(
        SessionPairStart{kApplicationID, uuid_from_hex(kWindowID), "Test Phone",
                         nonce(0x11)},
        0.0);
    auto actions = harness.server->receive(
        SessionPairDecision{uuid_from_hex(kSessionID), true}, 1.0);
    assert(as_reject(actions[0]).code == SessionRejectCode::PairingRejected);
    assert(harness.coordinator.fail_attempts == 1);
  }
  std::cout << "device_session pairing declines: ok\n";
}

void test_desktop_rejection_closes_with_pairing_rejected() {
  ServerHarness harness;
  harness.server->receive(
      SessionPairStart{kApplicationID, uuid_from_hex(kWindowID), "Test Phone",
                       nonce(0x11)},
      0.0);
  harness.server->receive(SessionPairDecision{uuid_from_hex(kAttemptID), true},
                          1.0);
  auto actions = harness.server->reject_pairing_on_desktop(2.0);
  assert(as_reject(actions[0]).code == SessionRejectCode::PairingRejected);
  assert(harness.coordinator.fail_attempts == 1);

  bool threw = false;
  try {
    (void)harness.server->reject_pairing_on_desktop(3.0);
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
  std::cout << "device_session desktop rejection: ok\n";
}

void test_invalid_granted_scopes_fail_the_attempt() {
  ServerHarness harness;
  harness.server->receive(
      SessionPairStart{kApplicationID, uuid_from_hex(kWindowID), "Test Phone",
                       nonce(0x11)},
      0.0);
  auto actions = harness.server->confirm_pairing_on_desktop(
      {"bad scope with spaces"}, 1.0);
  assert(as_reject(actions[0]).code == SessionRejectCode::PairingRejected);
  assert(harness.coordinator.fail_attempts == 1);
  assert(!harness.server->acceptance());
  std::cout << "device_session invalid scopes: ok\n";
}

void test_pairing_expiry_maps_to_pairing_expired() {
  ServerHarness harness;
  harness.coordinator.expires_at = 10.0;
  harness.server->receive(
      SessionPairStart{kApplicationID, uuid_from_hex(kWindowID), "Test Phone",
                       nonce(0x11)},
      0.0);
  auto actions = harness.server->expire(11.0);
  assert(as_reject(actions[0]).code == SessionRejectCode::PairingExpired);
  assert(harness.coordinator.expire_windows == 1);
  std::cout << "device_session pairing expiry: ok\n";
}

void test_post_tls_deadline_closes_without_reject() {
  ServerHarness harness;
  auto actions = harness.server->expire(111.0);
  assert(actions.size() == 1);
  assert(std::holds_alternative<SessionServerAction::Close>(actions[0].action));

  bool threw = false;
  try {
    (void)harness.server->receive(
        SessionAuthenticate{kApplicationID, uuid_from_hex(kDeviceID), nonce(0x11)},
        112.0);
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
  std::cout << "device_session post-tls deadline: ok\n";
}

void test_protocol_violations_close_poisonously() {
  ServerHarness harness;
  bool threw = false;
  try {
    // A server must never accept a server-direction record.
    (void)harness.server->receive(SessionAuthChallenge{nonce(0x22)}, 0.0);
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
  threw = false;
  try {
    (void)harness.server->receive(
        SessionAuthenticate{kApplicationID, uuid_from_hex(kDeviceID), nonce(0x11)},
        1.0);
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
  std::cout << "device_session violations: ok\n";
}

void test_disconnect_abandons_active_attempt() {
  ServerHarness harness;
  harness.server->receive(
      SessionPairStart{kApplicationID, uuid_from_hex(kWindowID), "Test Phone",
                       nonce(0x11)},
      0.0);
  harness.server->disconnect(1.0);
  assert(harness.coordinator.abandon_attempts == 1);
  bool threw = false;
  try {
    (void)harness.server->receive(
        SessionPairDecision{uuid_from_hex(kAttemptID), true}, 2.0);
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
  std::cout << "device_session disconnect: ok\n";
}

void test_sha256_known_vectors() {
  // FIPS 180-4 one-block and two-block vectors.
  assert(detail::sha256(Bytes{}) ==
         hex_bytes("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
  assert(detail::sha256(Bytes{'a', 'b', 'c'}) ==
         hex_bytes("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
  Bytes long_input(1000000, 'a');
  assert(detail::sha256(long_input) ==
         hex_bytes("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"));
  std::cout << "sha256 vectors: ok\n";
}

}  // namespace

int main() {
  try {
    test_sha256_known_vectors();
    test_golden_records_round_trip();
    test_decode_field_values();
    test_decoder_rejects_malformed_streams();
    test_reconnect_authenticates_and_accepts();
    test_reconnect_unknown_device_uses_dummy_credential();
    test_reconnect_wrong_application_id_fails_closed();
    test_pairing_completes_after_both_confirmations();
    test_pairing_rejects_declined_decision_and_unknown_attempts();
    test_desktop_rejection_closes_with_pairing_rejected();
    test_invalid_granted_scopes_fail_the_attempt();
    test_pairing_expiry_maps_to_pairing_expired();
    test_post_tls_deadline_closes_without_reject();
    test_protocol_violations_close_poisonously();
    test_disconnect_abandons_active_attempt();
  } catch (std::exception const& error) {
    std::cerr << "device session test failed: " << error.what() << "\n";
    return 1;
  }
  return 0;
}
