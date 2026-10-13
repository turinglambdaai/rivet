#pragma once

// WinUI 3 rolling-time-series chart for Rivet hosts.
//
// The control is a Canvas subclass built from ordinary XAML shapes: one
// persistent Polyline per series whose Points are updated in place, plus
// Line/TextBlock children for grid, thresholds, and markers that are
// rebuilt only when the geometry changes. Hosts instantiate it from
// code-behind (see examples/taskboard/windows) and feed it chart batches
// from the chart-batch event or a windowed pull.
//
// All methods must be called on the XAML UI thread, like every WinUI
// object; RVT1 event callbacks arrive on the reader thread and hosts must
// dispatch them through their DispatcherQueue first.

#include "rivet/chart_batch.hpp"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace rivet::win_ui {

struct ChartSeriesSpec final {
  std::string id;
  std::string label;
  std::string color;  // CSS color ("#3584e4")
  std::string unit;
};

struct ChartThreshold final {
  std::int64_t value;
  std::string label;
  std::string color;
};

struct ChartMarker final {
  std::int64_t ts_ns;
  std::string label;
};

class ChartControl final : public winrt::Microsoft::UI::Xaml::Controls::Canvas {
 public:
  ChartControl();

  void set_title(std::string title);
  void set_series(std::vector<ChartSeriesSpec> specs);
  void set_window(std::int64_t span_ns);
  void set_y_range(bool auto_scale, std::int64_t min, std::int64_t max);
  void set_thresholds(std::vector<ChartThreshold> thresholds);
  void set_markers(std::vector<ChartMarker> markers);

  void append_batch(std::string const& series_id, rivet::Bytes const& batch);
  void replace_series(std::string const& series_id,
                      std::vector<rivet::chart::Sample> window,
                      std::uint64_t watermark);
  void clear();

  // Fired on the UI thread when a batch gap means the host must re-pull
  // that series through its window RPC.
  std::function<void(std::string const& series_id)> on_gap;

 private:
  struct Entry final {
    ChartSeriesSpec spec;
    rivet::chart::SeriesModel model;
    winrt::Microsoft::UI::Xaml::Shapes::Polyline polyline{};
    winrt::Microsoft::UI::Xaml::Shapes::Ellipse cursor_dot{};
    bool has_cursor_dot{false};
  };

  struct Geometry {
    double left{};
    double top{};
    double width{};
    double height{};
    std::int64_t t_left{};
    std::int64_t newest{};
    std::int64_t v_min{};
    std::int64_t v_max{};

    bool operator==(Geometry const& other) const {
      return left == other.left && top == other.top && width == other.width &&
             height == other.height && t_left == other.t_left && newest == other.newest &&
             v_min == other.v_min && v_max == other.v_max;
    }
  };

  Entry* Find(std::string const& id);
  Geometry ComputeGeometry() const;
  void RebuildStatic(Geometry const& geometry);
  void UpdateSeriesPolylines(Geometry const& geometry);

  std::vector<Entry> entries_;
  std::vector<ChartThreshold> thresholds_;
  std::vector<ChartMarker> markers_;
  std::string title_;
  std::int64_t span_ns_{30LL * 1000 * 1000 * 1000};
  bool auto_scale_{true};
  std::int64_t y_min_{0};
  std::int64_t y_max_{0};
  bool static_built_{false};
  Geometry last_geometry_{};
};

}  // namespace rivet::win_ui
