#include "schannel_transport.hpp"

#include <schnlsp.h>

#include <cstring>
#include <stdexcept>
#include <string>
#include <utility>

namespace rivet::windows {
namespace {

constexpr std::size_t kMaxTLSCiphertextRecord = 18432;

void throw_status(char const* what, SECURITY_STATUS status) {
  throw std::runtime_error(std::string(what) + " failed (0x" +
                           std::to_string(static_cast<unsigned long>(status)) +
                           ")");
}

void throw_last_error(char const* what) {
  throw std::runtime_error(std::string(what) + " failed (error " +
                           std::to_string(WSAGetLastError()) + ")");
}

// One ALPN entry: a one-byte length followed by the protocol name, wrapped
// in the SEC_APPLICATION_PROTOCOLS envelope SChannel documents for
// AcceptSecurityContext input.
std::vector<std::uint8_t> alpn_input_buffer(
    std::string const& application_protocol) {
  std::vector<std::uint8_t> buffer;
  buffer.push_back(0x00);
  buffer.push_back(0x00);
  buffer.push_back(0x00);
  buffer.push_back(0x00);  // ProtocolListsSize placeholder
  std::uint16_t list_size = static_cast<std::uint16_t>(
      1 + 1 + application_protocol.size());  // ext byte + length byte + name
  buffer.push_back(static_cast<std::uint8_t>(list_size & 0xff));
  buffer.push_back(static_cast<std::uint8_t>(list_size >> 8));
  buffer.push_back(0x01);  // SecApplicationProtocolNegotiationExt_ALPN
  buffer.push_back(static_cast<std::uint8_t>(application_protocol.size()));
  buffer.insert(buffer.end(), application_protocol.begin(),
                application_protocol.end());
  std::uint32_t lists_size =
      static_cast<std::uint32_t>(buffer.size() - 4);
  std::memcpy(buffer.data(), &lists_size, sizeof(lists_size));
  return buffer;
}

}  // namespace

SchannelTransport::SchannelTransport(SOCKET socket, CERT_CONTEXT const* identity,
                                     std::uint16_t port)
    : socket_(socket) {
  (void)port;
  if (socket_ == INVALID_SOCKET || identity == nullptr) {
    throw std::runtime_error("invalid Rivet device TLS transport configuration");
  }

  SCHANNEL_CRED cred{};
  cred.dwVersion = SCHANNEL_CRED_VERSION;
  cred.cCreds = 1;
  PCCERT_CONTEXT certificate = identity;
  cred.paCred = &certificate;
  cred.grbitEnabledProtocols = SP_PROT_TLS1_2_SERVER
#ifdef SP_PROT_TLS1_3_SERVER
                               | SP_PROT_TLS1_3_SERVER
#endif
      ;
  cred.dwFlags = SCH_CRED_NO_SYSTEM_MAPPER | SCH_USE_STRONG_CRYPTO;

  SECURITY_STATUS status = AcquireCredentialsHandleW(
      nullptr, const_cast<LPWSTR>(UNISP_NAME_W), SECPKG_CRED_INBOUND, nullptr,
      &cred, nullptr, nullptr, &credentials_, nullptr);
  if (status != SEC_E_OK) {
    throw_status("acquiring TLS credentials", status);
  }
  has_credentials_ = true;
  try {
    handshake();
    SecPkgContext_StreamSizes sizes{};
    status = QueryContextAttributesW(&context_, SECPKG_ATTR_STREAM_SIZES,
                                     &sizes);
    if (status != SEC_E_OK) {
      throw_status("querying TLS stream sizes", status);
    }
    stream_sizes_ = sizes;
  } catch (...) {
    if (has_context_) {
      DeleteSecurityContext(&context_);
      has_context_ = false;
    }
    FreeCredentialsHandle(&credentials_);
    has_credentials_ = false;
    if (socket_ != INVALID_SOCKET) {
      closesocket(socket_);
      socket_ = INVALID_SOCKET;
    }
    throw;
  }
}

SchannelTransport::~SchannelTransport() {
  if (has_context_) {
    DeleteSecurityContext(&context_);
  }
  if (has_credentials_) {
    FreeCredentialsHandle(&credentials_);
  }
  if (socket_ != INVALID_SOCKET) {
    closesocket(socket_);
  }
}

void SchannelTransport::close() {
  if (socket_ != INVALID_SOCKET) {
    closesocket(socket_);
    socket_ = INVALID_SOCKET;
  }
}

std::size_t SchannelTransport::send_raw(std::uint8_t const* data,
                                        std::size_t size) {
  std::size_t sent = 0;
  while (sent < size) {
    int chunk = static_cast<int>(
        (size - sent) > INT_MAX ? INT_MAX : (size - sent));
    int result =
        ::send(socket_, reinterpret_cast<char const*>(data + sent), chunk, 0);
    if (result == SOCKET_ERROR) {
      throw_last_error("sending TLS data");
    }
    if (result == 0) {
      throw std::runtime_error("the Rivet device TLS socket closed on send");
    }
    sent += static_cast<std::size_t>(result);
  }
  return sent;
}

std::size_t SchannelTransport::receive_raw(std::uint8_t* data,
                                           std::size_t size) {
  int result = ::recv(socket_, reinterpret_cast<char*>(data),
                      static_cast<int>(size), 0);
  if (result == SOCKET_ERROR) {
    throw_last_error("receiving TLS data");
  }
  return static_cast<std::size_t>(result);
}

void SchannelTransport::handshake() {
  std::vector<std::uint8_t> alpn = alpn_input_buffer("rivet-device/1");
  std::vector<std::uint8_t> input;
  bool first_call = true;
  CtxtHandle* context_ptr = nullptr;
  unsigned long context_attributes = 0;
  SECURITY_STATUS status = SEC_I_CONTINUE_NEEDED;

  while (true) {
    SecBuffer input_buffers[3];
    SecBufferDesc input_desc{SECBUFFER_VERSION, 3, input_buffers};
    std::size_t consumed_extra = 0;
    input_buffers[0].BufferType = SECBUFFER_TOKEN;
    input_buffers[0].cbBuffer = static_cast<unsigned long>(input.size());
    input_buffers[0].pvBuffer = input.empty() ? nullptr : input.data();
    if (first_call) {
      input_buffers[1].BufferType = SECBUFFER_APPLICATION_PROTOCOLS;
      input_buffers[1].cbBuffer = static_cast<unsigned long>(alpn.size());
      input_buffers[1].pvBuffer = alpn.data();
    } else {
      input_buffers[1].BufferType = SECBUFFER_EMPTY;
      input_buffers[1].cbBuffer = 0;
      input_buffers[1].pvBuffer = nullptr;
    }
    input_buffers[2].BufferType = SECBUFFER_EMPTY;
    input_buffers[2].cbBuffer = 0;
    input_buffers[2].pvBuffer = nullptr;

    SecBuffer output_buffers[1];
    SecBufferDesc output_desc{SECBUFFER_VERSION, 1, output_buffers};
    output_buffers[0].BufferType = SECBUFFER_TOKEN;
    output_buffers[0].cbBuffer = 0;
    output_buffers[0].pvBuffer = nullptr;

    status = AcceptSecurityContext(
        &credentials_, context_ptr, &input_desc,
        ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_CONFIDENTIALITY |
            ASC_REQ_REPLAY_DETECT | ASC_REQ_STREAM,
        SECURITY_NATIVE_DREP, &context_, &output_desc, &context_attributes,
        nullptr);
    if (status == SEC_E_OK || status == SEC_I_CONTINUE_NEEDED ||
        status == SEC_E_INCOMPLETE_MESSAGE) {
      has_context_ = !first_call || status != SEC_E_INCOMPLETE_MESSAGE;
      context_ptr = &context_;
      first_call = false;
    }

    if (status == SEC_E_INCOMPLETE_MESSAGE) {
      // Keep everything accumulated so far and read more wire bytes.
      std::uint8_t chunk[4096];
      std::size_t received = receive_raw(chunk, sizeof(chunk));
      if (received == 0) {
        throw std::runtime_error("the TLS handshake ended mid-record");
      }
      input.insert(input.end(), chunk, chunk + received);
      continue;
    }

    if (input_buffers[1].BufferType == SECBUFFER_EXTRA &&
        input_buffers[1].cbBuffer > 0) {
      consumed_extra = input_buffers[1].cbBuffer;
    }
    input.erase(
        input.begin(),
        input.begin() + static_cast<std::ptrdiff_t>(input.size() - consumed_extra));

    if (output_buffers[0].cbBuffer > 0 && output_buffers[0].pvBuffer) {
      auto const* token = static_cast<std::uint8_t const*>(
          output_buffers[0].pvBuffer);
      try {
        send_raw(token, output_buffers[0].cbBuffer);
      } catch (...) {
        FreeContextBuffer(output_buffers[0].pvBuffer);
        throw;
      }
      FreeContextBuffer(output_buffers[0].pvBuffer);
    }

    if (status == SEC_E_OK) {
      break;
    }
    if (status != SEC_I_CONTINUE_NEEDED) {
      throw_status("the TLS handshake failed", status);
    }

    if (input.empty()) {
      std::uint8_t chunk[4096];
      std::size_t received = receive_raw(chunk, sizeof(chunk));
      if (received == 0) {
        throw std::runtime_error("the TLS handshake ended mid-record");
      }
      input.insert(input.end(), chunk, chunk + received);
    }
  }
}

bool SchannelTransport::decrypt_available() {
  return plaintext_offset_ < plaintext_.size();
}

void SchannelTransport::ensure_decrypted() {
  while (!decrypt_available()) {
    plaintext_.clear();
    plaintext_offset_ = 0;

    std::vector<std::uint8_t> ciphertext(kMaxTLSCiphertextRecord);
    std::size_t received = receive_raw(ciphertext.data(), ciphertext.size());
    if (received == 0) {
      // A clean EOF between records is the documented close.
      return;
    }

    SecBuffer buffers[4];
    buffers[0].BufferType = SECBUFFER_DATA;
    buffers[0].cbBuffer = static_cast<unsigned long>(received);
    buffers[0].pvBuffer = ciphertext.data();
    for (std::size_t i = 1; i < 4; ++i) {
      buffers[i].BufferType = SECBUFFER_EMPTY;
      buffers[i].cbBuffer = 0;
      buffers[i].pvBuffer = nullptr;
    }
    SecBufferDesc message{SECBUFFER_VERSION, 4, buffers};
    unsigned long ignored = 0;
    SECURITY_STATUS status = DecryptMessage(&context_, &message, 0, &ignored);
    if (status == SEC_E_INCOMPLETE_MESSAGE) {
      // Not enough wire bytes yet: retry with a larger read by feeding this
      // record back through the handshake-style accumulation path.
      std::vector<std::uint8_t> accumulated(ciphertext.begin(),
                                            ciphertext.begin() +
                                                static_cast<std::ptrdiff_t>(
                                                    received));
      while (status == SEC_E_INCOMPLETE_MESSAGE) {
        std::uint8_t chunk[4096];
        std::size_t more = receive_raw(chunk, sizeof(chunk));
        if (more == 0) {
          throw std::runtime_error("the TLS record ended mid-ciphertext");
        }
        accumulated.insert(accumulated.end(), chunk, chunk + more);
        buffers[0].cbBuffer = static_cast<unsigned long>(accumulated.size());
        buffers[0].pvBuffer = accumulated.data();
        status = DecryptMessage(&context_, &message, 0, &ignored);
      }
    } else if (status == SEC_I_CONTEXT_EXPIRED) {
      return;
    } else if (status == SEC_I_RENEGOTIATE) {
      throw std::runtime_error(
          "the Rivet device TLS peer attempted renegotiation");
    } else if (status != SEC_E_OK) {
      throw_status("decrypting TLS data", status);
    }

    for (std::size_t i = 0; i < 4; ++i) {
      if (buffers[i].BufferType == SECBUFFER_DATA && buffers[i].cbBuffer > 0) {
        auto const* data = static_cast<std::uint8_t const*>(buffers[i].pvBuffer);
        plaintext_.insert(plaintext_.end(), data, data + buffers[i].cbBuffer);
      }
    }
    // Extra bytes after one record are the next record's ciphertext; the
    // simple server loop re-reads them from the socket only when SChannel
    // did not retain them. SChannel reports leftovers as SECBUFFER_EXTRA —
    // fail closed rather than silently losing them.
    for (std::size_t i = 0; i < 4; ++i) {
      if (buffers[i].BufferType == SECBUFFER_EXTRA && buffers[i].cbBuffer > 0) {
        throw std::runtime_error(
            "unexpected extra TLS data after a decrypted record");
      }
    }
  }
}

bool SchannelTransport::read_exact(std::uint8_t* destination,
                                   std::size_t size) {
  while (size > 0) {
    ensure_decrypted();
    if (!decrypt_available()) {
      return false;  // clean EOF
    }
    std::size_t available = plaintext_.size() - plaintext_offset_;
    std::size_t take = size < available ? size : available;
    std::memcpy(destination, plaintext_.data() + plaintext_offset_, take);
    plaintext_offset_ += take;
    destination += take;
    size -= take;
  }
  return true;
}

void SchannelTransport::write_all(std::uint8_t const* source,
                                  std::size_t size) {
  std::size_t maximum =
      stream_sizes_.cbMaximumMessage > 0
          ? static_cast<std::size_t>(stream_sizes_.cbMaximumMessage)
          : 16384;
  std::vector<std::uint8_t> message(stream_sizes_.cbHeader + maximum +
                                    stream_sizes_.cbTrailer);
  while (size > 0) {
    std::size_t chunk = size < maximum ? size : maximum;
    std::memcpy(message.data() + stream_sizes_.cbHeader, source, chunk);
    SecBuffer buffers[4];
    buffers[0].BufferType = SECBUFFER_STREAM_HEADER;
    buffers[0].cbBuffer = stream_sizes_.cbHeader;
    buffers[0].pvBuffer = message.data();
    buffers[1].BufferType = SECBUFFER_DATA;
    buffers[1].cbBuffer = static_cast<unsigned long>(chunk);
    buffers[1].pvBuffer = message.data() + stream_sizes_.cbHeader;
    buffers[2].BufferType = SECBUFFER_STREAM_TRAILER;
    buffers[2].cbBuffer = stream_sizes_.cbTrailer;
    buffers[2].pvBuffer = message.data() + stream_sizes_.cbHeader + chunk;
    buffers[3].BufferType = SECBUFFER_EMPTY;
    buffers[3].cbBuffer = 0;
    buffers[3].pvBuffer = nullptr;
    SecBufferDesc message_desc{SECBUFFER_VERSION, 4, buffers};
    SECURITY_STATUS status = EncryptMessage(&context_, 0, &message_desc, 0);
    if (status != SEC_E_OK) {
      throw_status("encrypting TLS data", status);
    }
    std::size_t total = stream_sizes_.cbHeader + chunk +
                        stream_sizes_.cbTrailer;
    send_raw(message.data(), total);
    source += chunk;
    size -= chunk;
  }
}

}  // namespace rivet::windows
