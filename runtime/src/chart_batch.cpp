#include "rivet/chart_batch.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <string>

namespace rivet::chart {
namespace {

std::uint32_t ReadU32LE(std::uint8_t const* p) {
  return static_cast<std::uint32_t>(p[0]) |
         (static_cast<std::uint32_t>(p[1]) << 8) |
         (static_cast<std::uint32_t>(p[2]) << 16) |
         (static_cast<std::uint32_t>(p[3]) << 24);
}

std::int64_t ReadI64LE(std::uint8_t const* p) {
  std::uint64_t bits = 0;
  for (unsigned i = 8; i-- > 0;) {
    bits = (bits << 8) | static_cast<std::uint64_t>(p[i]);
  }
  std::int64_t value;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

void WriteU32LE(std::uint8_t* p, std::uint32_t v) {
  p[0] = static_cast<std::uint8_t>(v);
  p[1] = static_cast<std::uint8_t>(v >> 8);
  p[2] = static_cast<std::uint8_t>(v >> 16);
  p[3] = static_cast<std::uint8_t>(v >> 24);
}

void WriteI64LE(std::uint8_t* p, std::int64_t v) {
  std::uint64_t bits;
  std::memcpy(&bits, &v, sizeof(bits));
  for (unsigned i = 0; i < 8; ++i) {
    p[i] = static_cast<std::uint8_t>(bits >> (8 * i));
  }
}

constexpr std::size_t kHeaderSize = 16;
constexpr std::size_t kSampleSize = 16;

}  // namespace

Batch DecodeBatch(Bytes const& bytes) {
  if (bytes.size() < kHeaderSize) {
    throw std::runtime_error("rivet::chart batch shorter than its header: " +
                             std::to_string(bytes.size()));
  }
  std::uint8_t const* p = bytes.data();
  std::uint32_t const magic = ReadU32LE(p);
  if (magic != kBatchMagic) {
    throw std::runtime_error("rivet::chart batch magic mismatch: " +
                             std::to_string(magic));
  }
  std::uint32_t const count = ReadU32LE(p + 4);
  if (bytes.size() != kHeaderSize + static_cast<std::size_t>(count) * kSampleSize) {
    throw std::runtime_error("rivet::chart batch length does not match its count: " +
                             std::to_string(bytes.size()) + " vs " +
                             std::to_string(kHeaderSize +
                                            static_cast<std::size_t>(count) * kSampleSize));
  }
  Batch batch;
  std::uint64_t const first_bits = static_cast<std::uint64_t>(ReadI64LE(p + 8));
  batch.first_index = first_bits;
  batch.samples.reserve(count);
  for (std::uint32_t i = 0; i < count; ++i) {
    std::uint8_t const* s = p + kHeaderSize + static_cast<std::size_t>(i) * kSampleSize;
    batch.samples.push_back({ReadI64LE(s), ReadI64LE(s + 8)});
  }
  return batch;
}

Bytes EncodeBatch(std::vector<Sample> const& samples, std::uint64_t first_index) {
  Bytes bytes(kHeaderSize + samples.size() * kSampleSize);
  std::uint8_t* p = bytes.data();
  WriteU32LE(p, kBatchMagic);
  WriteU32LE(p + 4, static_cast<std::uint32_t>(samples.size()));
  std::int64_t const first_signed = static_cast<std::int64_t>(first_index);
  WriteI64LE(p + 8, first_signed);
  for (std::size_t i = 0; i < samples.size(); ++i) {
    std::uint8_t* s = p + kHeaderSize + i * kSampleSize;
    WriteI64LE(s, samples[i].ts_ns);
    WriteI64LE(s + 8, samples[i].value);
  }
  return bytes;
}

SeriesModel::SeriesModel(std::size_t capacity) : capacity_(capacity ? capacity : 1) {}

SeriesModel::ApplyResult SeriesModel::ApplyBatch(Batch const& batch) {
  if (batch.first_index + batch.samples.size() <= watermark_) {
    return ApplyResult::stale;
  }
  if (batch.first_index > watermark_) {
    return ApplyResult::gap;
  }
  // Partial overlap: skip the prefix the model already holds.
  std::size_t skip = static_cast<std::size_t>(watermark_ - batch.first_index);
  for (std::size_t i = skip; i < batch.samples.size(); ++i) {
    AppendLocal(batch.samples[i]);
  }
  watermark_ += batch.samples.size() - skip;
  return ApplyResult::appended;
}

void SeriesModel::AppendLocal(Sample sample) {
  if (!samples_.empty() && sample.ts_ns <= samples_.back().ts_ns) {
    throw std::runtime_error("rivet::chart sample timestamps must be strictly increasing");
  }
  samples_.push_back(sample);
  TrimToCapacity();
}

void SeriesModel::ResetFromWindow(std::vector<Sample> window, std::uint64_t watermark) {
  for (std::size_t i = 1; i < window.size(); ++i) {
    if (window[i].ts_ns <= window[i - 1].ts_ns) {
      throw std::runtime_error("rivet::chart window must be ts-ascending");
    }
  }
  samples_ = std::move(window);
  watermark_ = watermark;
  TrimToCapacity();
}

void SeriesModel::Clear() {
  samples_.clear();
  watermark_ = 0;
}

void SeriesModel::SetCapacity(std::size_t capacity) {
  capacity_ = capacity ? capacity : 1;
  TrimToCapacity();
}

std::int64_t SeriesModel::newest_ts() const {
  return samples_.empty() ? 0 : samples_.back().ts_ns;
}

std::size_t SeriesModel::WindowStartNs(std::int64_t span_ns) const {
  if (samples_.empty() || span_ns < 0) {
    return 0;
  }
  std::int64_t const cutoff = newest_ts() - span_ns;
  auto it = std::lower_bound(samples_.begin(), samples_.end(), cutoff,
                             [](Sample const& s, std::int64_t c) { return s.ts_ns < c; });
  return static_cast<std::size_t>(it - samples_.begin());
}

void SeriesModel::TrimToCapacity() {
  // Erase in chunks so a steady append stream amortizes the front erase
  // instead of paying a memmove per sample.
  if (samples_.size() <= capacity_) {
    return;
  }
  std::size_t const over = samples_.size() - capacity_;
  std::size_t const chunk = std::max<std::size_t>(over, capacity_ / 4);
  std::size_t const remove = std::min<std::size_t>(chunk, samples_.size());
  samples_.erase(samples_.begin(), samples_.begin() + static_cast<std::ptrdiff_t>(remove));
}

}  // namespace rivet::chart
