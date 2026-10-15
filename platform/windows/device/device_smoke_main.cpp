// Standalone acceptance smoke for the Windows device gateway: creates the
// identity, prints its pin, starts the listener and the DNS-SD
// advertisement, optionally opens the pairing window, and serves preface
// sessions through the portable host. With no stored pairings, reconnect
// attempts take the documented unknown-device path (fresh challenge, dummy
// HMAC, `authentication_failed`), and pairing attempts answer
// `pairing_unavailable` — enough to verify the full TLS + ALPN + preface
// path from a real companion client.
//
//   RivetDeviceSmoke.exe            # run until Enter
//   RivetDeviceSmoke.exe --pair     # same, with the pairing window open
//
// Exit code 0 means every step succeeded.

#include <windows.h>
#include <bcrypt.h>

#include <cstdio>
#include <iostream>
#include <memory>
#include <string>

#include "device_session_service.hpp"

#pragma comment(lib, "bcrypt")

namespace {

using namespace rivet;
using namespace rivet::windows;

std::string hex_digest(std::vector<std::uint8_t> const& bytes) {
  static char const* digits = "0123456789abcdef";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (std::uint8_t byte : bytes) {
    out.push_back(digits[byte >> 4]);
    out.push_back(digits[byte & 0x0f]);
  }
  return out;
}

// Empty boundaries: no stored pairings and no open pairing window, so the
// state machine exercises its documented negative paths.
class NullStore final : public SessionPairingStore {
 public:
  std::optional<SessionStoredPairing> load(SessionUuid const&) override {
    return std::nullopt;
  }
  void save(SessionStoredPairing const&) override {}
};

class NullCoordinator final : public SessionPairingCoordinator {
 public:
  SessionPairingChallenge begin_attempt(SessionUuid const&, std::string const&,
                                        Bytes const&, double) override {
    throw SessionPairingError::WindowUnavailable;
  }
  std::optional<SessionPairingResult> confirm_on_desktop(
      SessionUuid const&, SessionUuid const&,
      std::vector<std::string> const&, double) override {
    return std::nullopt;
  }
  std::optional<SessionPairingResult> confirm_on_device(SessionUuid const&,
                                                        SessionUuid const&,
                                                        double) override {
    return std::nullopt;
  }
  void fail_attempt(SessionUuid const&, SessionUuid const&, double) override {}
  void abandon_attempt(SessionUuid const&, SessionUuid const&,
                       double) override {}
  void expire_window(double) override {}
};

class NullRandom final : public SessionRandomBytes {
 public:
  Bytes random_bytes(std::size_t count) override {
    Bytes value(count);
    BCryptGenRandom(nullptr, value.data(),
                    static_cast<unsigned long>(value.size()),
                    BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    return value;
  }
};

class NullUuids final : public SessionUuidGenerator {
 public:
  SessionUuid next_uuid() override { return SessionUuid{}; }
};

double system_now() {
  FILETIME filetime;
  GetSystemTimeAsFileTime(&filetime);
  ULARGE_INTEGER value{{filetime.dwLowDateTime, filetime.dwHighDateTime}};
  // Windows epoch to Unix epoch, 100ns ticks to seconds.
  return static_cast<double>(value.QuadPart - 116444736000000000ULL) /
         10000000.0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  bool open_pairing = false;
  for (int i = 1; i < argc; ++i) {
    if (std::wstring(argv[i]) == L"--pair") {
      open_pairing = true;
    }
  }

  try {
    auto identity = DeviceIdentity::load_or_create(L"Rivet Device Gateway");
    std::wprintf(L"identity certificate ready; spki-sha256 %hs\n",
                 hex_digest(identity.spki_sha256()).c_str());

    std::string advertisement_id;
    {
      unsigned char random_bytes[16];
      BCryptGenRandom(nullptr, random_bytes, sizeof(random_bytes),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG);
      static char const* digits = "0123456789abcdef";
      for (std::uint8_t byte : random_bytes) {
        advertisement_id.push_back(digits[byte >> 4]);
        advertisement_id.push_back(digits[byte & 0x0f]);
      }
    }

    NullStore store;
    NullCoordinator coordinator;
    NullRandom random;
    NullUuids uuids;

    DeviceSessionService service(
        identity, advertisement_id,
        [&](Transport& transport)
            -> std::unique_ptr<DeviceSessionHost> {
          double started_at = system_now();
          return std::make_unique<DeviceSessionHost>(
              transport,
              [&](double) {
                return std::make_unique<DeviceSessionServer>(
                    "com.example.smoke", identity.spki_sha256(), &store,
                    &coordinator, &random, &uuids,
                    kSessionDefaultMaximumPayload,
                    kSessionDefaultMaximumPending, 10.0, started_at);
              },
              [](SessionUuid const&, std::string const&, double) {},
              [](SessionAcceptance const&, Transport&) {},
              [] { return system_now(); });
        });

    service.start();
    std::wprintf(L"listener ready on port %u; advertisement id %hs\n",
                 service.port(), service.advertisement_id().c_str());
    std::wprintf(
        L"dns-sd: browse _rivet-device._tcp from another host on the LAN\n");
    if (open_pairing) {
      service.set_pairing_window_open(true);
      std::wprintf(L"pairing window open\n");
    }
    std::wprintf(L"press Enter to stop\n");
    std::wstring line;
    std::getline(std::wcin, line);
    service.stop();
    std::wprintf(L"stopped cleanly\n");
    return 0;
  } catch (std::exception const& error) {
    std::wprintf(L"smoke failed: %hs\n", error.what());
    return 1;
  }
}
