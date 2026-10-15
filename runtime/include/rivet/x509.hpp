#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace rivet {

// Extracts the complete SubjectPublicKeyInfo field (the full TLV, including
// its header) from a DER-encoded X.509 certificate. Companion platforms pin
// the SHA-256 of exactly these bytes — the same value macOS computes from
// Security.framework, so a reconnect pin matches across implementations.
// Throws std::runtime_error on malformed input.
std::vector<std::uint8_t> x509_subject_public_key_info(
    std::vector<std::uint8_t> const& certificate_der);

std::array<std::uint8_t, 32> x509_spki_sha256(
    std::vector<std::uint8_t> const& certificate_der);

}  // namespace rivet
