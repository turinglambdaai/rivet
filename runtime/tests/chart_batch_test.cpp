#include "rivet/chart_batch.hpp"

#include <cassert>
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace {

using rivet::chart::Batch;
using rivet::Bytes;
using rivet::chart::Sample;
using rivet::chart::SeriesModel;

// Decode-on-top-of-encode keeps every model assertion exercising the wire
// path as well.
Batch MakeBatch(std::vector<Sample> samples, std::uint64_t first_index) {
  return rivet::chart::DecodeBatch(rivet::chart::EncodeBatch(samples, first_index));
}

void test_decode_golden() {
  // Encoded by rivet/chart.rkt: two samples starting at absolute index 7.
  Bytes const golden{
      0x31, 0x43, 0x56, 0x52, 0x02, 0x00, 0x00, 0x00,
      0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0xf4, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
  Batch batch = rivet::chart::DecodeBatch(golden);
  assert(batch.first_index == 7);
  assert(batch.samples.size() == 2);
  assert(batch.samples[0].ts_ns == 1);
  assert(batch.samples[0].value == -12);
  assert(batch.samples[1].ts_ns == 2);
  assert(batch.samples[1].value == 40);
}

void test_roundtrip() {
  std::vector<Sample> samples;
  for (int i = 0; i < 500; ++i) {
    samples.push_back({static_cast<std::int64_t>(i) * 1000,
                       static_cast<std::int64_t>(i % 37) - 18});
  }
  Bytes bytes = rivet::chart::EncodeBatch(samples, 4242);
  Batch batch = rivet::chart::DecodeBatch(bytes);
  assert(batch.first_index == 4242);
  assert(batch.samples.size() == samples.size() &&
         std::equal(batch.samples.begin(), batch.samples.end(), samples.begin(),
                    [](Sample const& a, Sample const& b) {
                      return a.ts_ns == b.ts_ns && a.value == b.value;
                    }));
}

void test_rejects_malformed() {
  bool threw = false;
  try {
    rivet::chart::DecodeBatch(Bytes{'s', 'h', 'o'});
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);

  threw = false;
  try {
    rivet::chart::DecodeBatch(Bytes(32, 0x00));
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);

  // Header declares two samples but only one payload follows.
  Bytes short_count{
      0x31, 0x43, 0x56, 0x52, 0x02, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
  threw = false;
  try {
    rivet::chart::DecodeBatch(short_count);
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
}

void test_model_apply_states() {
  SeriesModel model;
  assert(model.ApplyBatch(MakeBatch({{1, 10}}, 0)) ==
         SeriesModel::ApplyResult::appended);
  assert(model.watermark() == 1);
  assert(model.size() == 1);

  // Same batch again is stale, not duplicate data.
  assert(model.ApplyBatch(MakeBatch({{1, 10}}, 0)) ==
         SeriesModel::ApplyResult::stale);

  // A batch starting beyond the watermark is a gap.
  assert(model.ApplyBatch(MakeBatch({{5, 50}}, 3)) ==
         SeriesModel::ApplyResult::gap);

  // Partial overlap applies only the suffix.
  assert(model.ApplyBatch(MakeBatch({{2, 20}, {3, 30}, {4, 40}}, 1)) ==
         SeriesModel::ApplyResult::appended);
  assert(model.watermark() == 4);
  assert(model.size() == 4);
  assert(model.newest_ts() == 4);
}

void test_model_window() {
  SeriesModel model;
  model.ApplyBatch(MakeBatch({{0, 0}, {100, 1}, {200, 2}, {10000, 3}}, 0));
  assert(model.WindowStartNs(500) == 3);
  assert(model.WindowStartNs(10000) == 0);
  assert(model.WindowStartNs(0) == 3);
}

void test_model_trim_and_reset() {
  SeriesModel model(4);
  model.ApplyBatch(MakeBatch({{1, 1}, {2, 2}, {3, 3}, {4, 4}, {5, 5}, {6, 6}}, 0));
  assert(model.size() <= 4);
  assert(model.watermark() == 6);
  assert(model.newest_ts() == 6);

  model.ResetFromWindow({{100, 1}, {200, 2}}, 8);
  assert(model.watermark() == 8);
  assert(model.newest_ts() == 200);

  bool threw = false;
  try {
    model.AppendLocal({150, 0});
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);

  model.Clear();
  assert(model.empty());
  assert(model.watermark() == 0);
}

}  // namespace

int main() {
  test_decode_golden();
  test_roundtrip();
  test_rejects_malformed();
  test_model_apply_states();
  test_model_window();
  test_model_trim_and_reset();
  return 0;
}
