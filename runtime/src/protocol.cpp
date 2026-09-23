#include "rivet/protocol.hpp"

#include <algorithm>
#include <array>
#include <climits>
#include <cstring>
#include <stdexcept>
#include <type_traits>
#include <utility>

namespace rivet {
namespace {

constexpr std::array<std::uint8_t, 4> kMagic{'R', 'V', 'T', '1'};

enum class ValueTag : std::uint8_t {
  Null = 0x00,
  False = 0x01,
  True = 0x02,
  Int64 = 0x03,
  String = 0x04,
  Bytes = 0x05,
  List = 0x06,
};

MessageType decode_message_type(std::uint8_t raw) {
  switch (raw) {
    case 1: return MessageType::Hello;
    case 2: return MessageType::Request;
    case 3: return MessageType::Response;
    case 4: return MessageType::Error;
    case 5: return MessageType::Event;
    case 6: return MessageType::Cancel;
    case 7: return MessageType::Shutdown;
    default: throw std::runtime_error("unknown Rivet message type");
  }
}

bool is_continuation(std::uint8_t byte) {
  return (byte & 0xc0u) == 0x80u;
}

bool valid_utf8(std::uint8_t const* data, std::size_t size) {
  std::size_t i = 0;
  while (i < size) {
    auto const first = data[i];
    if (first <= 0x7f) {
      ++i;
      continue;
    }
    if (first >= 0xc2 && first <= 0xdf) {
      if (i + 1 >= size || !is_continuation(data[i + 1])) return false;
      i += 2;
      continue;
    }
    if (first == 0xe0) {
      if (i + 2 >= size || data[i + 1] < 0xa0 || data[i + 1] > 0xbf ||
          !is_continuation(data[i + 2])) return false;
      i += 3;
      continue;
    }
    if ((first >= 0xe1 && first <= 0xec) || (first >= 0xee && first <= 0xef)) {
      if (i + 2 >= size || !is_continuation(data[i + 1]) ||
          !is_continuation(data[i + 2])) return false;
      i += 3;
      continue;
    }
    if (first == 0xed) {
      if (i + 2 >= size || data[i + 1] < 0x80 || data[i + 1] > 0x9f ||
          !is_continuation(data[i + 2])) return false;
      i += 3;
      continue;
    }
    if (first == 0xf0) {
      if (i + 3 >= size || data[i + 1] < 0x90 || data[i + 1] > 0xbf ||
          !is_continuation(data[i + 2]) || !is_continuation(data[i + 3])) return false;
      i += 4;
      continue;
    }
    if (first >= 0xf1 && first <= 0xf3) {
      if (i + 3 >= size || !is_continuation(data[i + 1]) ||
          !is_continuation(data[i + 2]) || !is_continuation(data[i + 3])) return false;
      i += 4;
      continue;
    }
    if (first == 0xf4) {
      if (i + 3 >= size || data[i + 1] < 0x80 || data[i + 1] > 0x8f ||
          !is_continuation(data[i + 2]) || !is_continuation(data[i + 3])) return false;
      i += 4;
      continue;
    }
    return false;
  }
  return true;
}

void append_u32(Bytes& out, std::uint32_t value) {
  for (int i = 0; i < 4; ++i) {
    out.push_back(static_cast<std::uint8_t>((value >> (8 * i)) & 0xff));
  }
}

void append_u64(Bytes& out, std::uint64_t value) {
  for (int i = 0; i < 8; ++i) {
    out.push_back(static_cast<std::uint8_t>((value >> (8 * i)) & 0xff));
  }
}

std::uint32_t read_u32(std::uint8_t const* data) {
  std::uint32_t value = 0;
  for (int i = 0; i < 4; ++i) {
    value |= static_cast<std::uint32_t>(data[i]) << (8 * i);
  }
  return value;
}

std::uint64_t read_u64(std::uint8_t const* data) {
  std::uint64_t value = 0;
  for (int i = 0; i < 8; ++i) {
    value |= static_cast<std::uint64_t>(data[i]) << (8 * i);
  }
  return value;
}

class Reader {
 public:
  explicit Reader(Bytes const& bytes) : bytes_(bytes) {}

  std::uint8_t byte() {
    require(1);
    return bytes_[offset_++];
  }

  std::uint32_t u32() {
    require(4);
    auto const value = read_u32(bytes_.data() + offset_);
    offset_ += 4;
    return value;
  }

  std::uint64_t u64() {
    require(8);
    auto const value = read_u64(bytes_.data() + offset_);
    offset_ += 8;
    return value;
  }

  Bytes bytes(std::size_t size) {
    require(size);
    Bytes result(bytes_.begin() + static_cast<std::ptrdiff_t>(offset_),
                 bytes_.begin() + static_cast<std::ptrdiff_t>(offset_ + size));
    offset_ += size;
    return result;
  }

  bool empty() const noexcept { return offset_ == bytes_.size(); }
  std::size_t remaining() const noexcept { return bytes_.size() - offset_; }

 private:
  void require(std::size_t size) const {
    if (size > bytes_.size() - offset_) {
      throw std::runtime_error("truncated Rivet value payload");
    }
  }

  Bytes const& bytes_;
  std::size_t offset_{};
};

void consume_encode_node(std::size_t& remaining_nodes) {
  if (remaining_nodes == 0) {
    throw std::length_error("Rivet value node count exceeds protocol limit");
  }
  --remaining_nodes;
}

void consume_decode_node(std::size_t& remaining_nodes) {
  if (remaining_nodes == 0) {
    throw std::runtime_error("Rivet value node count exceeds protocol limit");
  }
  --remaining_nodes;
}

void encode_into(Bytes& out,
                 Value const& value,
                 std::size_t depth,
                 std::size_t& remaining_nodes) {
  consume_encode_node(remaining_nodes);
  std::visit(
      [&](auto const& data) {
        using T = std::decay_t<decltype(data)>;
        if constexpr (std::is_same_v<T, std::monostate>) {
          out.push_back(static_cast<std::uint8_t>(ValueTag::Null));
        } else if constexpr (std::is_same_v<T, bool>) {
          out.push_back(static_cast<std::uint8_t>(data ? ValueTag::True : ValueTag::False));
        } else if constexpr (std::is_same_v<T, std::int64_t>) {
          out.push_back(static_cast<std::uint8_t>(ValueTag::Int64));
          std::uint64_t bits = 0;
          static_assert(sizeof(bits) == sizeof(data));
          std::memcpy(&bits, &data, sizeof(bits));
          append_u64(out, bits);
        } else if constexpr (std::is_same_v<T, std::string>) {
          auto const* raw = reinterpret_cast<std::uint8_t const*>(data.data());
          if (!valid_utf8(raw, data.size())) {
            throw std::runtime_error("invalid UTF-8 in Rivet string");
          }
          out.push_back(static_cast<std::uint8_t>(ValueTag::String));
          if (data.size() > UINT32_MAX) {
            throw std::length_error("Rivet string exceeds protocol limit");
          }
          append_u32(out, static_cast<std::uint32_t>(data.size()));
          out.insert(out.end(), data.begin(), data.end());
        } else if constexpr (std::is_same_v<T, Bytes>) {
          out.push_back(static_cast<std::uint8_t>(ValueTag::Bytes));
          if (data.size() > UINT32_MAX) {
            throw std::length_error("Rivet byte vector exceeds protocol limit");
          }
          append_u32(out, static_cast<std::uint32_t>(data.size()));
          out.insert(out.end(), data.begin(), data.end());
        } else if constexpr (std::is_same_v<T, Value::List>) {
          if (depth >= kMaxValueDepth) {
            throw std::length_error("Rivet value nesting exceeds protocol limit");
          }
          if (data.size() > UINT32_MAX) {
            throw std::length_error("Rivet list exceeds protocol limit");
          }
          if (data.size() > remaining_nodes) {
            throw std::length_error("Rivet value node count exceeds protocol limit");
          }
          out.push_back(static_cast<std::uint8_t>(ValueTag::List));
          append_u32(out, static_cast<std::uint32_t>(data.size()));
          for (auto const& item : data) {
            encode_into(out, item, depth + 1, remaining_nodes);
          }
        }
      },
      value.data);
}

Value decode_one(Reader& reader,
                 std::size_t depth,
                 std::size_t& remaining_nodes) {
  consume_decode_node(remaining_nodes);
  auto const tag = static_cast<ValueTag>(reader.byte());
  switch (tag) {
    case ValueTag::Null:
      return Value{};
    case ValueTag::False:
      return Value(false);
    case ValueTag::True:
      return Value(true);
    case ValueTag::Int64: {
      auto const bits = reader.u64();
      std::int64_t value = 0;
      static_assert(sizeof(bits) == sizeof(value));
      std::memcpy(&value, &bits, sizeof(value));
      return Value(value);
    }
    case ValueTag::String: {
      auto const raw = reader.bytes(reader.u32());
      if (!valid_utf8(raw.data(), raw.size())) {
        throw std::runtime_error("invalid UTF-8 in Rivet string");
      }
      return Value(std::string(raw.begin(), raw.end()));
    }
    case ValueTag::Bytes:
      return Value(reader.bytes(reader.u32()));
    case ValueTag::List: {
      if (depth >= kMaxValueDepth) {
        throw std::runtime_error("Rivet value nesting exceeds protocol limit");
      }
      Value::List list;
      auto const count = reader.u32();
      // Every declared element consumes at least one value node. Enforce this
      // before reserving memory so a tiny payload cannot request a huge vector.
      if (count > remaining_nodes) {
        throw std::runtime_error("Rivet value node count exceeds protocol limit");
      }
      // Every encoded item also needs at least one tag byte.
      if (count > reader.remaining()) {
        throw std::runtime_error("impossible Rivet list length");
      }
      list.reserve(count);
      for (std::uint32_t i = 0; i < count; ++i) {
        list.push_back(decode_one(reader, depth + 1, remaining_nodes));
      }
      return Value(std::move(list));
    }
  }
  throw std::runtime_error("unknown Rivet value tag");
}

}  // namespace

void write_frame(Transport& transport, Frame const& frame) {
  (void)decode_message_type(static_cast<std::uint8_t>(frame.type));
  if (frame.payload.size() > kMaxFramePayloadSize) {
    throw std::length_error("Rivet frame payload exceeds protocol limit");
  }

  Bytes header;
  header.reserve(18);
  header.insert(header.end(), kMagic.begin(), kMagic.end());
  header.push_back(kProtocolVersion);
  header.push_back(static_cast<std::uint8_t>(frame.type));
  append_u64(header, frame.id);
  append_u32(header, static_cast<std::uint32_t>(frame.payload.size()));

  transport.write_all(header.data(), header.size());
  if (!frame.payload.empty()) {
    transport.write_all(frame.payload.data(), frame.payload.size());
  }
  transport.flush();
}

std::optional<Frame> read_frame(Transport& transport) {
  std::array<std::uint8_t, 18> header{};
  if (!transport.read_exact(header.data(), header.size())) {
    return std::nullopt;
  }

  if (!std::equal(kMagic.begin(), kMagic.end(), header.begin())) {
    throw std::runtime_error("invalid Rivet frame magic");
  }
  if (header[4] != kProtocolVersion) {
    throw std::runtime_error("unsupported Rivet protocol version");
  }

  Frame frame;
  frame.type = decode_message_type(header[5]);
  frame.id = read_u64(header.data() + 6);
  auto const payload_size = read_u32(header.data() + 14);
  if (payload_size > kMaxFramePayloadSize) {
    throw std::length_error("Rivet frame payload exceeds protocol limit");
  }
  frame.payload.resize(payload_size);
  if (payload_size != 0 &&
      !transport.read_exact(frame.payload.data(), frame.payload.size())) {
    throw std::runtime_error("unexpected EOF in Rivet frame payload");
  }
  return frame;
}

Bytes encode_value(Value const& value) {
  Bytes result;
  std::size_t remaining_nodes = kMaxValueNodes;
  encode_into(result, value, 0, remaining_nodes);
  return result;
}

Value decode_value(Bytes const& bytes) {
  Reader reader(bytes);
  std::size_t remaining_nodes = kMaxValueNodes;
  auto value = decode_one(reader, 0, remaining_nodes);
  if (!reader.empty()) {
    throw std::runtime_error("trailing bytes after Rivet value");
  }
  return value;
}

}  // namespace rivet
