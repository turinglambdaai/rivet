#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace rivet {

inline constexpr std::uint8_t kProtocolVersion = 1;

enum class MessageType : std::uint8_t {
  Hello = 1,
  Request = 2,
  Response = 3,
  Error = 4,
  Event = 5,
  Cancel = 6,
  Shutdown = 7,
};

using Bytes = std::vector<std::uint8_t>;

struct Value {
  using List = std::vector<Value>;
  using Data = std::variant<std::monostate, bool, std::int64_t, std::string, Bytes, List>;

  Data data;

  Value() = default;
  Value(bool v) : data(v) {}
  Value(std::int64_t v) : data(v) {}
  Value(std::string v) : data(std::move(v)) {}
  Value(char const* v) : data(std::string(v)) {}
  Value(Bytes v) : data(std::move(v)) {}
  Value(List v) : data(std::move(v)) {}
};

struct Frame {
  MessageType type{};
  std::uint64_t id{};
  Bytes payload;
};

// A tiny transport boundary shared by anonymous pipes, named pipes and test
// transports. `read_exact` returns false only when clean EOF happens before
// any byte of the requested region is read; partial reads must be completed or
// reported as an exception by the implementation.
class Transport {
 public:
  virtual ~Transport() = default;
  virtual bool read_exact(std::uint8_t* destination, std::size_t size) = 0;
  virtual void write_all(std::uint8_t const* source, std::size_t size) = 0;
  virtual void flush() = 0;
};

void write_frame(Transport& transport, Frame const& frame);
std::optional<Frame> read_frame(Transport& transport);

Bytes encode_value(Value const& value);
Value decode_value(Bytes const& bytes);

}  // namespace rivet
