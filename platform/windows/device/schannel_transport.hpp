#pragma once

#include <winsock2.h>
#include <windows.h>
#include <wincrypt.h>
#include <sspi.h>

#include <cstddef>
#include <cstdint>
#include <vector>

#include "rivet/protocol.hpp"

#pragma comment(lib, "secur32")
#pragma comment(lib, "ws2_32")

namespace rivet::windows {

// A server-side TLS 1.2+ stream over an already connected socket, backed by
// SChannel and the gateway identity. The constructor performs the blocking
// handshake — including the `rivet-device/1` ALPN offer, which the session
// contract requires — and closes the socket on any failure, so a half-open
// TLS socket never survives. Decryption is fail-closed: renegotiation and
// protocol errors end the transport instead of downgrading.
class SchannelTransport final : public rivet::Transport {
 public:
  SchannelTransport(SOCKET socket, CERT_CONTEXT const* identity,
                    std::uint16_t port);
  ~SchannelTransport() override;

  SchannelTransport(SchannelTransport const&) = delete;
  SchannelTransport& operator=(SchannelTransport const&) = delete;

  bool read_exact(std::uint8_t* destination, std::size_t size) override;
  void write_all(std::uint8_t const* source, std::size_t size) override;
  void flush() override {}

  // Closes the socket immediately, unblocking a pending read. Idempotent.
  void close();

 private:
  void handshake();
  std::size_t send_raw(std::uint8_t const* data, std::size_t size);
  std::size_t receive_raw(std::uint8_t* data, std::size_t size);
  bool decrypt_available();
  void ensure_decrypted();

  SOCKET socket_;
  CredHandle credentials_{};
  CtxtHandle context_{};
  bool has_context_ = false;
  bool has_credentials_ = false;
  SecPkgContext_StreamSizes stream_sizes_{};
  std::vector<std::uint8_t> plaintext_;
  std::size_t plaintext_offset_ = 0;
  std::vector<std::uint8_t> pending_handshake_;
};

}  // namespace rivet::windows
