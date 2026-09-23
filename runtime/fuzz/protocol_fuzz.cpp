#include "rivet/protocol.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <utility>

namespace {

class MemoryTransport final : public rivet::Transport {
 public:
  MemoryTransport() = default;
  explicit MemoryTransport(rivet::Bytes bytes) : bytes_(std::move(bytes)) {}

  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    if (read_offset_ == bytes_.size()) {
      return false;
    }
    if (size > bytes_.size() - read_offset_) {
      throw std::runtime_error("truncated fuzz transport");
    }
    if (size != 0) {
      std::memcpy(destination, bytes_.data() + read_offset_, size);
    }
    read_offset_ += size;
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    bytes_.insert(bytes_.end(), source, source + size);
  }

  void flush() override {}

  rivet::Bytes const& bytes() const noexcept { return bytes_; }

 private:
  rivet::Bytes bytes_;
  std::size_t read_offset_{};
};

[[noreturn]] void invariant_failure() { std::abort(); }

void fuzz_value(rivet::Bytes const& input) {
  std::optional<rivet::Value> decoded;
  try {
    decoded = rivet::decode_value(input);
  } catch (std::exception const&) {
    return;
  }

  // Anything accepted by the decoder must be representable by the encoder and
  // produce one stable canonical byte sequence on subsequent round trips.
  auto const canonical = rivet::encode_value(*decoded);
  auto const decoded_again = rivet::decode_value(canonical);
  if (rivet::encode_value(decoded_again) != canonical) {
    invariant_failure();
  }
}

void fuzz_frame(rivet::Bytes const& input) {
  std::optional<rivet::Frame> decoded;
  try {
    MemoryTransport transport(input);
    decoded = rivet::read_frame(transport);
  } catch (std::exception const&) {
    return;
  }

  if (!decoded.has_value()) {
    return;
  }

  // A frame accepted from arbitrary bytes must always be writable and readable
  // again without changing its wire-visible fields.
  MemoryTransport canonical_transport;
  rivet::write_frame(canonical_transport, *decoded);

  MemoryTransport verify_transport(canonical_transport.bytes());
  auto const decoded_again = rivet::read_frame(verify_transport);
  if (!decoded_again.has_value() || decoded_again->type != decoded->type ||
      decoded_again->id != decoded->id || decoded_again->payload != decoded->payload) {
    invariant_failure();
  }
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(std::uint8_t const* data, std::size_t size) {
  // The protocol itself permits 64 MiB payloads. The fuzz runner controls its
  // own practical max_len; keeping the harness independent of that policy also
  // makes it suitable for longer external fuzz campaigns.
  if (size > rivet::kMaxFramePayloadSize + 18ULL) {
    return 0;
  }

  rivet::Bytes input(data, data + size);
  fuzz_value(input);
  fuzz_frame(input);
  return 0;
}
