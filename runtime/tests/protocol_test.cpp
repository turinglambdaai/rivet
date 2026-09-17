#include "rivet/protocol.hpp"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {

class MemoryTransport final : public rivet::Transport {
 public:
  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    if (read_offset_ == bytes_.size()) {
      return false;
    }
    if (size > bytes_.size() - read_offset_) {
      throw std::runtime_error("partial read");
    }
    std::memcpy(destination, bytes_.data() + read_offset_, size);
    read_offset_ += size;
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    bytes_.insert(bytes_.end(), source, source + size);
  }

  void flush() override {}

 private:
  std::vector<std::uint8_t> bytes_;
  std::size_t read_offset_{};
};

}  // namespace

int main() {
  rivet::Value::List request_values;
  request_values.emplace_back("increment");
  request_values.emplace_back(std::int64_t{41});

  rivet::Frame outgoing{
      rivet::MessageType::Request,
      7,
      rivet::encode_value(rivet::Value(std::move(request_values))),
  };

  MemoryTransport transport;
  rivet::write_frame(transport, outgoing);
  auto incoming = rivet::read_frame(transport);

  assert(incoming.has_value());
  assert(incoming->type == rivet::MessageType::Request);
  assert(incoming->id == 7);

  auto decoded = rivet::decode_value(incoming->payload);
  auto const& list = std::get<rivet::Value::List>(decoded.data);
  assert(list.size() == 2);
  assert(std::get<std::string>(list[0].data) == "increment");
  assert(std::get<std::int64_t>(list[1].data) == 41);

  return 0;
}
