#include "rivet/x509.hpp"

#include <algorithm>
#include <stdexcept>
#include <string>
#include <utility>

#include "rivet/detail/sha256.hpp"

namespace rivet {
namespace {

struct DerElement {
  std::uint8_t tag{};
  std::size_t header_length{};
  std::size_t content_offset{};
  std::size_t content_length{};
};

// Reads one DER TLV at `offset`; identifiers are single-byte (no high tag
// numbers appear in X.509), and lengths up to four long-form bytes are
// accepted, which covers every certificate a gateway will ever load.
DerElement read_der(std::vector<std::uint8_t> const& der, std::size_t offset) {
  if (offset >= der.size()) {
    throw std::runtime_error("truncated DER certificate");
  }
  DerElement element;
  element.tag = der[offset];
  std::size_t cursor = offset + 1;
  if (cursor >= der.size()) {
    throw std::runtime_error("truncated DER certificate");
  }
  std::uint8_t first = der[cursor];
  ++cursor;
  if (first < 0x80) {
    element.content_length = first;
  } else {
    std::size_t length_bytes = first & 0x7fu;
    if (length_bytes == 0 || length_bytes > 4 || cursor + length_bytes > der.size()) {
      throw std::runtime_error("malformed DER certificate length");
    }
    element.content_length = 0;
    for (std::size_t i = 0; i < length_bytes; ++i) {
      element.content_length =
          (element.content_length << 8) | der[cursor + i];
    }
    cursor += length_bytes;
  }
  element.header_length = cursor - offset;
  element.content_offset = cursor;
  if (element.content_offset + element.content_length > der.size()) {
    throw std::runtime_error("truncated DER certificate");
  }
  return element;
}

DerElement expect(std::vector<std::uint8_t> const& der, std::size_t offset,
                  std::uint8_t tag, char const* what) {
  DerElement element = read_der(der, offset);
  if (element.tag != tag) {
    throw std::runtime_error(
        std::string("unexpected DER element in ") + what);
  }
  return element;
}

constexpr std::uint8_t kTagSequence = 0x30;
constexpr std::uint8_t kTagContextZero = 0xa0;
constexpr std::uint8_t kTagInteger = 0x02;

}  // namespace

std::vector<std::uint8_t> x509_subject_public_key_info(
    std::vector<std::uint8_t> const& certificate_der) {
  DerElement certificate =
      expect(certificate_der, 0, kTagSequence, "certificate");
  std::size_t cursor = certificate.content_offset;
  DerElement tbs = expect(certificate_der, cursor, kTagSequence,
                          "tbsCertificate");
  cursor = tbs.content_offset;

  // [0] EXPLICIT version is optional (absent in v1 certificates).
  if (cursor < tbs.content_offset + tbs.content_length &&
      certificate_der[cursor] == kTagContextZero) {
    cursor = read_der(certificate_der, cursor).content_offset +
             read_der(certificate_der, cursor).content_length;
  }
  // serialNumber, signature, issuer, validity, subject — skipped wholesale.
  for (int required = 0; required < 5; ++required) {
    DerElement field = read_der(certificate_der, cursor);
    if (required == 0) {
      expect(certificate_der, cursor, kTagInteger, "serialNumber");
    }
    cursor = field.content_offset + field.content_length;
  }
  DerElement spki = read_der(certificate_der, cursor);
  std::size_t end = spki.content_offset + spki.content_length;
  return std::vector<std::uint8_t>(certificate_der.begin() +
                                       static_cast<std::ptrdiff_t>(cursor),
                                   certificate_der.begin() +
                                       static_cast<std::ptrdiff_t>(end));
}

std::array<std::uint8_t, 32> x509_spki_sha256(
    std::vector<std::uint8_t> const& certificate_der) {
  std::vector<std::uint8_t> spki =
      x509_subject_public_key_info(certificate_der);
  std::array<std::uint8_t, 32> digest{};
  auto hashed = detail::sha256(spki);
  std::copy(hashed.begin(), hashed.end(), digest.begin());
  return digest;
}

}  // namespace rivet
