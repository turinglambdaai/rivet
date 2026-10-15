#pragma once

#include <winsock2.h>
#include <windows.h>
#include <wincrypt.h>

#include <memory>
#include <string>
#include <vector>

namespace rivet::windows {

// The per-install TLS identity for the Rivet device gateway: a P-256
// self-signed certificate with a persistent CNG key in the user's personal
// store, located by its Rivet friendly-name property. Rotation is deletion
// plus a fresh create, which invalidates every pin and pairing credential,
// exactly like the macOS identity.
class DeviceIdentity {
 public:
  // Loads the current certificate carrying `friendly_name`, or creates a
  // new one when absent. Throws std::runtime_error on system failures.
  static DeviceIdentity load_or_create(std::wstring const& friendly_name);

  // Deletes every certificate and key carrying `friendly_name`. Missing
  // identities are not an error.
  static void delete_identity(std::wstring const& friendly_name);

  // SHA-256 over the certificate's SubjectPublicKeyInfo — the value
  // companions pin, byte-identical with the portable implementation.
  std::vector<std::uint8_t> spki_sha256() const;

  PCCERT_CONTEXT context() const noexcept { return context_.get(); }

 private:
  struct ContextDeleter {
    void operator()(CERT_CONTEXT const* context) const noexcept;
  };

  explicit DeviceIdentity(const CERT_CONTEXT* context);

  std::unique_ptr<CERT_CONTEXT const, ContextDeleter> context_;
};

}  // namespace rivet::windows
