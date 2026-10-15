#include "rivet/device_session_host.hpp"

#include <cassert>
#include <chrono>
#include <cstring>
#include <exception>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace rivet;

constexpr char const* kApplicationID = "com.example.app";
constexpr char const* kDeviceID = "00112233445566778899aabbccddeeff";
constexpr char const* kAttemptID = "ffeeddccbbaa99887766554433221100";
constexpr char const* kSessionID = "0123456789abcdef0123456789abcdef";

SessionUuid uuid_from_hex(std::string const& hex) {
  auto nibble = [](char value) {
    if (value >= '0' && value <= '9') return static_cast<std::uint8_t>(value - '0');
    return static_cast<std::uint8_t>(10 + value - 'a');
  };
  SessionUuid id;
  for (std::size_t i = 0; i < id.size(); ++i) {
    id[i] = static_cast<std::uint8_t>((nibble(hex[i * 2]) << 4) |
                                      nibble(hex[i * 2 + 1]));
  }
  return id;
}

Bytes nonce(std::uint8_t fill) { return Bytes(kSessionNonceSize, fill); }
Bytes credential(std::uint8_t fill) { return Bytes(kSessionCredentialSize, fill); }
Bytes fingerprint(std::uint8_t fill) { return Bytes(kSessionFingerprintSize, fill); }

// A pipe-like transport whose reader blocks until data arrives or the
// transport is closed, mirroring a real socket for cancellation tests.
class BlockingTransport final : public Transport {
 public:
  void feed(Bytes bytes) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      input_.insert(input_.end(), bytes.begin(), bytes.end());
    }
    readable_cv_.notify_all();
  }

  void close_input() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      closed_ = true;
    }
    readable_cv_.notify_all();
  }

  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    std::unique_lock<std::mutex> lock(mutex_);
    readable_cv_.wait(lock, [this, size] {
      return input_.size() - read_offset_ >= size || closed_;
    });
    if (input_.size() - read_offset_ < size) {
      return false;
    }
    std::memcpy(destination, input_.data() + read_offset_, size);
    read_offset_ += size;
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    std::lock_guard<std::mutex> lock(mutex_);
    written_.insert(written_.end(), source, source + size);
    written_cv_.notify_all();
  }

  void flush() override {}

  void wait_written(std::size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    written_cv_.wait(lock, [this, count] { return written_.size() >= count; });
  }

  Bytes written() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return written_;
  }

  // Blocks until one complete session record has been written.
  Bytes wait_record() {
    for (int i = 0; i < 500; ++i) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (written_.size() >= 8) {
          std::size_t payload = static_cast<std::size_t>(written_[6]) |
                                (static_cast<std::size_t>(written_[7]) << 8);
          if (written_.size() >= 8 + payload) {
            return written_;
          }
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    throw std::runtime_error("timed out waiting for a host write");
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable readable_cv_;
  std::condition_variable written_cv_;
  Bytes input_;
  std::size_t read_offset_{};
  bool closed_{};
  Bytes written_;
};

// The session state machine fixtures are shared with device_session_test; to
// keep this file self-contained they are redefined compactly here.
class StoreLike final : public SessionPairingStore {
 public:
  std::optional<SessionStoredPairing> load(
      SessionUuid const& device_id) override {
    if (pairing && pairing->device.id == device_id) return pairing;
    return std::nullopt;
  }
  void save(SessionStoredPairing const& value) override {
    saved.push_back(value);
    pairing = value;
  }
  std::optional<SessionStoredPairing> pairing;
  std::vector<SessionStoredPairing> saved;
};

class CoordinatorLike final : public SessionPairingCoordinator {
 public:
  SessionPairingChallenge begin_attempt(SessionUuid const&,
                                        std::string const&,
                                        Bytes const&, double) override {
    return SessionPairingChallenge{uuid_from_hex(kAttemptID), nonce(0x22),
                                   "222296", expires_at};
  }
  std::optional<SessionPairingResult> confirm_on_desktop(
      SessionUuid const&, SessionUuid const&,
      std::vector<std::string> const& granted, double) override {
    if (!result) return std::nullopt;
    granted_scopes = granted;
    desktop_confirmed = true;
    return result;
  }
  std::optional<SessionPairingResult> confirm_on_device(SessionUuid const&,
                                                        SessionUuid const&,
                                                        double) override {
    if (desktop_confirmed) return result;
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
  double expires_at = 10000.0;
  std::optional<SessionPairingResult> result;
  std::vector<std::string> granted_scopes;
  bool desktop_confirmed = false;
  int fail_attempts = 0;
  int abandon_attempts = 0;
  int expire_windows = 0;
};

class RandomLike final : public SessionRandomBytes {
 public:
  Bytes random_bytes(std::size_t count) override {
    return Bytes(count, 0x22);
  }
};

class UuidsLike final : public SessionUuidGenerator {
 public:
  SessionUuid next_uuid() override { return uuid_from_hex(kSessionID); }
};

SessionPairedDevice paired_device() {
  SessionPairedDevice device;
  device.id = uuid_from_hex(kDeviceID);
  device.application_id = kApplicationID;
  device.name = "Test Phone";
  device.scope_names = {"reader"};
  device.server_fingerprint = fingerprint(0x51);
  device.created_at = 90.0;
  device.last_used_at = 90.0;
  return device;
}

Bytes encode(SessionMessage const& message) {
  return encode_session_record(message);
}

// Runs the host on its own thread and joins at scope exit. Exceptions do
// not cross std::thread boundaries, so they are captured and rethrown by
// `join`.
struct HostRun {
  explicit HostRun(DeviceSessionHost& host)
      : thread_([&host, this] {
          try {
            host.run();
          } catch (...) {
            error_ = std::current_exception();
          }
        }) {}
  ~HostRun() {
    if (thread_.joinable()) thread_.join();
  }
  void join() {
    if (thread_.joinable()) thread_.join();
    if (error_) std::rethrow_exception(error_);
  }
  std::thread thread_;
  std::exception_ptr error_;
};

void test_reconnect_drives_preface_and_lends_stream() {
  BlockingTransport transport;
  StoreLike store;
  store.pairing = SessionStoredPairing{paired_device(), credential(0x33)};
  CoordinatorLike coordinator;
  RandomLike random;
  UuidsLike uuids;
  double clock = 100.0;

  std::optional<SessionAcceptance> lent_acceptance;
  bool application_ran = false;
  DeviceSessionHost host(
      transport,
      [&](double) {
        return std::make_unique<DeviceSessionServer>(
            kApplicationID, fingerprint(0x51), &store, &coordinator, &random,
            &uuids, kSessionDefaultMaximumPayload, kSessionDefaultMaximumPending,
            10.0, clock);
      },
      [](SessionUuid const&, std::string const&, double) {},
      [&](SessionAcceptance const& acceptance, Transport& borrowed) {
        application_ran = true;
        lent_acceptance = acceptance;
        // Ordinary RVT1 bytes flow after acceptance; read one frame back to
        // prove the same stream is lent onward.
        Bytes echoed = encode(SessionAuthProof{credential(0x44)});
        borrowed.write_all(echoed.data(), echoed.size());
        borrowed.flush();
      },
      [&clock] { return clock; });

  transport.feed(encode(SessionAuthenticate{
      kApplicationID, uuid_from_hex(kDeviceID), nonce(0x11)}));
  HostRun run(host);
  Bytes challenge = transport.wait_record();
  auto decoded = decode_session_record(challenge);
  assert(std::holds_alternative<SessionAuthChallenge>(decoded));

  // The proof arrives one logical second later, so the refreshed
  // last-used timestamp moves forward.
  clock = 101.0;
  Bytes proof = session_authentication_proof(
      credential(0x33), kApplicationID, fingerprint(0x51),
      uuid_from_hex(kDeviceID), nonce(0x11), nonce(0x22));
  transport.feed(encode(SessionAuthProof{proof}));
  run.join();

  assert(application_ran);
  assert(lent_acceptance);
  assert(lent_acceptance->session_id == uuid_from_hex(kSessionID));
  assert(store.saved.size() == 1);
  assert(store.saved[0].device.last_used_at == 101.0);
  std::cout << "device_session_host reconnect: ok\n";
}

void test_pairing_waits_for_desktop_decision() {
  BlockingTransport transport;
  StoreLike store;
  CoordinatorLike coordinator;
  coordinator.expires_at = 10000.0;
  RandomLike random;
  UuidsLike uuids;
  double clock = 100.0;

  std::string shown_code;
  DeviceSessionHost host(
      transport,
      [&](double) {
        return std::make_unique<DeviceSessionServer>(
            kApplicationID, fingerprint(0x51), &store, &coordinator, &random,
            &uuids, kSessionDefaultMaximumPayload, kSessionDefaultMaximumPending,
            10.0, clock);
      },
      [&](SessionUuid const&, std::string const& code, double) {
        shown_code = code;
      },
      [](SessionAcceptance const&, Transport&) {},
      [&clock] { return clock; });

  transport.feed(encode(SessionPairStart{
      kApplicationID, uuid_from_hex("102132435465768798a9bacbdcedfe0f"),
      "Test Phone", nonce(0x11)}));
  HostRun run(host);
  transport.wait_record();
  transport.feed(encode(SessionPairDecision{uuid_from_hex(kAttemptID), true}));
  // Give the run thread time to reach the desktop-decision wait.
  std::this_thread::sleep_for(std::chrono::milliseconds(50));

  // The device user's confirmation alone must not complete the session.
  assert(shown_code == "222296");
  assert(!coordinator.desktop_confirmed);

  // The desktop user confirms on another thread, like the real UI would.
  coordinator.result = SessionPairingResult{paired_device(), credential(0x33)};
  auto actions = host.confirm_pairing_on_desktop({"reader"});
  assert(actions.size() == 2);
  run.join();

  Bytes written = transport.written();
  assert(written.size() > 24);
  std::cout << "device_session_host pairing: ok\n";
}

void test_desktop_rejection_closes_cleanly() {
  BlockingTransport transport;
  StoreLike store;
  CoordinatorLike coordinator;
  RandomLike random;
  UuidsLike uuids;
  double clock = 100.0;

  bool application_ran = false;
  DeviceSessionHost host(
      transport,
      [&](double) {
        return std::make_unique<DeviceSessionServer>(
            kApplicationID, fingerprint(0x51), &store, &coordinator, &random,
            &uuids, kSessionDefaultMaximumPayload, kSessionDefaultMaximumPending,
            10.0, clock);
      },
      [](SessionUuid const&, std::string const&, double) {},
      [&](SessionAcceptance const&, Transport&) { application_ran = true; },
      [&clock] { return clock; });

  transport.feed(encode(SessionPairStart{
      kApplicationID, uuid_from_hex("102132435465768798a9bacbdcedfe0f"),
      "Test Phone", nonce(0x11)}));
  HostRun run(host);
  transport.wait_record();
  transport.feed(encode(SessionPairDecision{uuid_from_hex(kAttemptID), true}));
  std::this_thread::sleep_for(std::chrono::milliseconds(50));

  auto actions = host.reject_pairing_on_desktop();
  assert(actions.size() == 2);
  run.join();
  assert(!application_ran);
  assert(coordinator.fail_attempts == 1);
  std::cout << "device_session_host rejection: ok\n";
}

void test_post_tls_deadline_times_out() {
  BlockingTransport transport;
  StoreLike store;
  CoordinatorLike coordinator;
  RandomLike random;
  UuidsLike uuids;
  double clock = 100.0;

  bool application_ran = false;
  DeviceSessionHost host(
      transport,
      [&](double) {
        return std::make_unique<DeviceSessionServer>(
            kApplicationID, fingerprint(0x51), &store, &coordinator, &random,
            &uuids, kSessionDefaultMaximumPayload, kSessionDefaultMaximumPending,
            10.0, clock);
      },
      [](SessionUuid const&, std::string const&, double) {},
      [&](SessionAcceptance const&, Transport&) { application_ran = true; },
      [&clock] { return clock; });

  bool timed_out = false;
  {
    transport.feed(encode(SessionAuthenticate{
        kApplicationID, uuid_from_hex(kDeviceID), nonce(0x11)}));
    HostRun run(host);
    transport.wait_record();
    // No auth proof arrives; a late record lands past the post-TLS deadline
    // and the host must answer with its own expiry, not a protocol error.
    clock = 200.0;
    transport.feed(encode(SessionAuthenticate{
        kApplicationID, uuid_from_hex(kDeviceID), nonce(0x11)}));
    try {
      run.join();
    } catch (DeviceSessionHostError const&) {
      timed_out = true;
    }
  }
  assert(timed_out);
  assert(!application_ran);
  std::cout << "device_session_host deadline: ok\n";
}

void test_cancel_wakes_desktop_wait() {
  BlockingTransport transport;
  StoreLike store;
  CoordinatorLike coordinator;
  RandomLike random;
  UuidsLike uuids;
  double clock = 100.0;

  bool application_ran = false;
  DeviceSessionHost host(
      transport,
      [&](double) {
        return std::make_unique<DeviceSessionServer>(
            kApplicationID, fingerprint(0x51), &store, &coordinator, &random,
            &uuids, kSessionDefaultMaximumPayload, kSessionDefaultMaximumPending,
            10.0, clock);
      },
      [](SessionUuid const&, std::string const&, double) {},
      [&](SessionAcceptance const&, Transport&) { application_ran = true; },
      [&clock] { return clock; });

  transport.feed(encode(SessionPairStart{
      kApplicationID, uuid_from_hex("102132435465768798a9bacbdcedfe0f"),
      "Test Phone", nonce(0x11)}));
  HostRun run(host);
  transport.wait_record();
  transport.feed(encode(SessionPairDecision{uuid_from_hex(kAttemptID), true}));
  std::this_thread::sleep_for(std::chrono::milliseconds(50));

  host.cancel();
  run.join();
  assert(!application_ran);
  assert(coordinator.abandon_attempts == 1);
  std::cout << "device_session_host cancel: ok\n";
}

void test_malformed_preface_fails_closed() {
  BlockingTransport transport;
  StoreLike store;
  CoordinatorLike coordinator;
  RandomLike random;
  UuidsLike uuids;
  double clock = 100.0;

  bool application_ran = false;
  DeviceSessionHost host(
      transport,
      [&](double) {
        return std::make_unique<DeviceSessionServer>(
            kApplicationID, fingerprint(0x51), &store, &coordinator, &random,
            &uuids, kSessionDefaultMaximumPayload, kSessionDefaultMaximumPending,
            10.0, clock);
      },
      [](SessionUuid const&, std::string const&, double) {},
      [&](SessionAcceptance const&, Transport&) { application_ran = true; },
      [&clock] { return clock; });

  bool threw = false;
  {
    HostRun run(host);
    transport.feed(Bytes{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07});
    try {
      run.join();
    } catch (std::runtime_error const&) {
      threw = true;
    }
  }
  assert(threw);
  assert(!application_ran);
  std::cout << "device_session_host malformed preface: ok\n";
}

}  // namespace

int main() {
  try {
    test_reconnect_drives_preface_and_lends_stream();
    test_pairing_waits_for_desktop_decision();
    test_desktop_rejection_closes_cleanly();
    test_post_tls_deadline_times_out();
    test_cancel_wakes_desktop_wait();
    test_malformed_preface_fails_closed();
  } catch (std::exception const& error) {
    std::cerr << "device session host test failed: " << error.what() << "\n";
    return 1;
  }
  return 0;
}
