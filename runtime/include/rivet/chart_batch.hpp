#pragma once

// Real-time chart series data plane, C++ side.
//
// The batch layout is the cross-language contract defined by
// rivet/chart.rkt: little-endian u32 magic 0x52564331 ("RVC1"), u32 sample
// count, i64 absolute first index, then count x (i64 timestamp-ns, i64
// value). The Swift decoder in platform/macos/Sources/RivetUI mirrors this
// file; tests/chart.rkt pins the shared golden bytes.

#include "rivet/protocol.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace rivet::chart {

inline constexpr std::uint32_t kBatchMagic = 0x52564331u;

struct Sample final {
  std::int64_t ts_ns{0};
  std::int64_t value{0};
};

struct Batch final {
  std::uint64_t first_index{0};
  std::vector<Sample> samples;
};

// Throws std::runtime_error with a diagnostic naming the violated field;
// never reads past the declared sizes.
Batch DecodeBatch(Bytes const& bytes);

// Used by the golden test and by simulators; hosts normally only decode.
Bytes EncodeBatch(std::vector<Sample> const& samples, std::uint64_t first_index);

// Host-side per-series accumulator.
//
// The model tracks the watermark (the next absolute index it expects) so a
// widget can tell an in-order batch from a stale replay and from a gap
// caused by ring eviction on the Racket side. A gap is not repaired here:
// the application must re-pull the window through its typed RPC and call
// ResetFromWindow.
class SeriesModel final {
 public:
  enum class ApplyResult { appended, stale, gap };

  explicit SeriesModel(std::size_t capacity = 16384);

  SeriesModel(SeriesModel const&) = delete;
  SeriesModel& operator=(SeriesModel const&) = delete;
  SeriesModel(SeriesModel&&) = default;
  SeriesModel& operator=(SeriesModel&&) = default;

  ApplyResult ApplyBatch(Batch const& batch);
  void AppendLocal(Sample sample);
  void ResetFromWindow(std::vector<Sample> window, std::uint64_t watermark);

  void Clear();
  void SetCapacity(std::size_t capacity);

  std::size_t size() const { return samples_.size(); }
  bool empty() const { return samples_.empty(); }
  Sample const* data() const { return samples_.data(); }
  std::uint64_t watermark() const { return watermark_; }
  std::int64_t newest_ts() const;

  // Index of the first sample not older than newest_ts() - span_ns. The
  // samples are ts-ascending, so this is a lower_bound search.
  std::size_t WindowStartNs(std::int64_t span_ns) const;

 private:
  void TrimToCapacity();

  std::vector<Sample> samples_;
  std::size_t capacity_;
  std::uint64_t watermark_{0};
};

}  // namespace rivet::chart
