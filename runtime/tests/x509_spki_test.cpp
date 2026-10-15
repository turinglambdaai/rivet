#include "rivet/protocol.hpp"
#include "rivet/x509.hpp"

#include <cassert>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using namespace rivet;

Bytes hex_bytes(std::string const& hex) {
  auto nibble = [](char value) {
    if (value >= '0' && value <= '9') return static_cast<std::uint8_t>(value - '0');
    if (value >= 'a' && value <= 'f') return static_cast<std::uint8_t>(10 + value - 'a');
    if (value >= 'A' && value <= 'F') return static_cast<std::uint8_t>(10 + value - 'A');
    throw std::runtime_error("bad hex in fixture");
  };
  Bytes bytes;
  bytes.reserve(hex.size() / 2);
  for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
    bytes.push_back(static_cast<std::uint8_t>((nibble(hex[i]) << 4) |
                                              nibble(hex[i + 1])));
  }
  return bytes;
}

// A real P-256 self-signed certificate generated with OpenSSL; the expected
// SPKI digest below matches `openssl x509 -pubkey | openssl pkey -pubin
// -outform DER | sha256sum` for exactly this DER.
constexpr char const* kGoldenCert =
    "30820212308201b8020900bf0be14af993e2f8300a06082a8648ce3d0403023017311530"
    "1306035504030c0c526976657420476f6c64656e301e170d323631303135303334353031"
    "5a170d3236313131343033343530315a30173115301306035504030c0c52697665742047"
    "6f6c64656e3082014b3082010306072a8648ce3d02013081f7020101302c06072a8648ce"
    "3d0101022100ffffffff00000001000000000000000000000000ffffffffffffffffffff"
    "ffff305b0420ffffffff00000001000000000000000000000000ffffffffffffffffffff"
    "fffc04205ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b"
    "031500c49d360886e704936a6678e1139d26b7819f7e900441046b17d1f2e12c4247f8bc"
    "e6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f"
    "9e162bce33576b315ececbb6406837bf51f5022100ffffffff00000000ffffffffffffff"
    "ffbce6faada7179e84f3b9cac2fc63255102010103420004eaac99eb4fce3933cc2507f4"
    "96180c8ea4b71db5e2b61744828576d0f813c8f90c98d5278f8f14bc5af9d99688b2358f"
    "932b4605658ef5a510ede6f9825bcf01300a06082a8648ce3d0403020348003045022100"
    "add621685ebaaa557cb0bf592658d00efcb8b0c9d2fcc3af4658498b1e6c82ac02202c9d"
    "6bc63ad93776b5c91b82a827fdb98cbf0bbbdf5ff7e78777d6073170f75f";

void test_golden_spki_extraction() {
  Bytes certificate = hex_bytes(kGoldenCert);
  assert(certificate.size() == 534);

  Bytes spki = x509_subject_public_key_info(certificate);
  assert(spki.size() == 335);
  assert(spki[0] == 0x30);
  assert(spki[1] == 0x82);
  assert(spki[2] == 0x01);
  assert(spki[3] == 0x4b);

  auto digest = x509_spki_sha256(certificate);
  auto expected = hex_bytes(
      "d4123eee28e47300c78e4f8d73ebbccc215bee4fb0d72c79835928c357e6b871");
  assert(std::vector<std::uint8_t>(digest.begin(), digest.end()) == expected);
  std::cout << "x509 spki golden: ok\n";
}

void test_malformed_certificates_fail() {
  bool threw = false;
  try {
    (void)x509_subject_public_key_info(Bytes{0x30, 0x03, 0x30, 0x01, 0x01});
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);

  threw = false;
  try {
    (void)x509_subject_public_key_info(Bytes{0x02, 0x01, 0x00});
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);

  threw = false;
  try {
    (void)x509_subject_public_key_info(Bytes{0x30, 0xff, 0x00});
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
  std::cout << "x509 spki rejects: ok\n";
}

}  // namespace

int main() {
  try {
    test_golden_spki_extraction();
    test_malformed_certificates_fail();
  } catch (std::exception const& error) {
    std::cerr << "x509 spki test failed: " << error.what() << "\n";
    return 1;
  }
  return 0;
}
