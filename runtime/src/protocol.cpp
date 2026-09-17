#include "rivet/protocol.hpp"

#include <array>
#include <cstring>
#include <stdexcept>
#include <type_traits>

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

 private:
  void require(std::size_t size) const {
    if (size > bytes_.size() - offset_) {
      throw std::runtime_error("truncated Rivet value payload");
    }
  }

  Bytes const& bytes_;
  std::size_t offset_{};
};

void encode_into(Bytes& out, Value const& value) {
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
          out.push_back(static_cast<std::uint8_t>(ValueTag::List));
          if (data.size() > UINT32_MAX) {
            throw std::length_error("Rivet list exceeds protocol limit");
          }
          append_u32(out, static_cast<std::uint32_t>(data.size()));
          for (auto const& item : data) {
            encode_into(out, item);
          }
        }
      },
      value.data);
}

Value decode_one(Reader& reader) {
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
      return Value(std::string(raw.begin(), raw.end()));
    }
    case ValueTag::Bytes:
      return Value(reader.bytes(reader.u32()));
    case ValueTag::List: {
      Value::List list;
      auto const count = reader.u32();
      list.reserve(count);
      for (std::uint32_t i = 0; i < count; ++i) {
        list.push_back(decode_one(reader));
      }
      return Value(std::move(list));
    }
  }
  throw std::runtime_error("unknown Rivet value tag");
}

}  // namespace

void write_frame(Transport& transport, Frame const& frame) {
  if (frame.payload.size() > UINT32_MAX) {
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
  frame.type = static_cast<MessageType>(header[5]);
  frame.id = read_u64(header.data() + 6);
  auto const payload_size = read_u32(header.data() + 14);
  frame.payload.resize(payload_size);
  if (payload_size != 0 &&
      !transport.read_exact(frame.payload.data(), frame.payload.size())) {
    throw std::runtime_error("unexpected EOF in Rivet frame payload");
  }
  return frame;
}

Bytes encode_value(Value const& value) {
  Bytes result;
  encode_into(result, value);
  return result;
}

Value decode_value(Bytes const& bytes) {
  Reader reader(bytes);
  auto value = decode_one(reader);
  if (!reader.empty()) {
    throw std::runtime_error("trailing bytes after Rivet value");
  }
  return value;
}

}  // namespace rivet
