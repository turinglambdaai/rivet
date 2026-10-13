#include <windows.h>

#include "rivet_chart_control.hpp"

#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <utility>

using namespace winrt::Microsoft::UI::Xaml;
using namespace winrt::Microsoft::UI::Xaml::Controls;
using namespace winrt::Microsoft::UI::Xaml::Media;
using namespace winrt::Microsoft::UI::Xaml::Shapes;

namespace rivet::win_ui {
namespace {

constexpr double kMarginLeft = 68.0;
constexpr double kMarginRight = 18.0;
constexpr double kMarginTop = 24.0;
constexpr double kMarginBottom = 30.0;

winrt::Windows::UI::Color ParseColor(std::string const& text,
                                    winrt::Windows::UI::Color fallback) {
  std::string hex = text;
  if (!hex.empty() && hex[0] == '#') {
    hex.erase(0, 1);
  }
  unsigned value = 0;
  bool ok = !hex.empty() && hex.size() <= 8;
  for (char c : hex) {
    value <<= 4;
    if (c >= '0' && c <= '9') {
      value |= static_cast<unsigned>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      value |= static_cast<unsigned>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      value |= static_cast<unsigned>(c - 'A' + 10);
    } else {
      ok = false;
      break;
    }
  }
  if (!ok) {
    return fallback;
  }
  winrt::Windows::UI::Color color{};
  if (hex.size() == 6) {
    color.A = 255;
    color.R = static_cast<uint8_t>((value >> 16) & 0xff);
    color.G = static_cast<uint8_t>((value >> 8) & 0xff);
    color.B = static_cast<uint8_t>(value & 0xff);
  } else if (hex.size() == 8) {
    color.A = static_cast<uint8_t>((value >> 24) & 0xff);
    color.R = static_cast<uint8_t>((value >> 16) & 0xff);
    color.G = static_cast<uint8_t>((value >> 8) & 0xff);
    color.B = static_cast<uint8_t>(value & 0xff);
  } else {
    return fallback;
  }
  return color;
}

std::wstring ToWide(std::string const& text) {
  if (text.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), wide.data(), size);
  return wide;
}

std::string FormatScaled(std::int64_t value, std::string const& unit) {
  char buf[64];
  double magnitude = std::abs(static_cast<double>(value));
  if (magnitude >= 1e9) {
    std::snprintf(buf, sizeof(buf), "%.2fG", static_cast<double>(value) / 1e9);
  } else if (magnitude >= 1e6) {
    std::snprintf(buf, sizeof(buf), "%.2fM", static_cast<double>(value) / 1e6);
  } else if (magnitude >= 1e3) {
    std::snprintf(buf, sizeof(buf), "%.2fk", static_cast<double>(value) / 1e3);
  } else if (magnitude >= 1) {
    std::snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(value));
  } else if (magnitude > 0) {
    std::snprintf(buf, sizeof(buf), "%.0fn", static_cast<double>(value));
  } else {
    std::snprintf(buf, sizeof(buf), "0");
  }
  return unit.empty() ? std::string(buf) : std::string(buf) + unit;
}

std::string FormatDurationNs(std::int64_t ns) {
  char buf[64];
  double magnitude = std::abs(static_cast<double>(ns));
  if (magnitude >= 1e9) {
    std::snprintf(buf, sizeof(buf), "%.2fs", static_cast<double>(ns) / 1e9);
  } else if (magnitude >= 1e6) {
    std::snprintf(buf, sizeof(buf), "%.1fms", static_cast<double>(ns) / 1e6);
  } else if (magnitude >= 1e3) {
    std::snprintf(buf, sizeof(buf), "%.0fus", static_cast<double>(ns) / 1e3);
  } else {
    std::snprintf(buf, sizeof(buf), "%lldns", static_cast<long long>(ns));
  }
  return buf;
}

double NiceStep(double raw) {
  if (raw <= 0) {
    return 1.0;
  }
  double exponent = std::floor(std::log10(raw));
  double fraction = raw / std::pow(10.0, exponent);
  double nice;
  if (fraction <= 1.0) {
    nice = 1.0;
  } else if (fraction <= 2.0) {
    nice = 2.0;
  } else if (fraction <= 5.0) {
    nice = 5.0;
  } else {
    nice = 10.0;
  }
  return nice * std::pow(10.0, exponent);
}

Brush DimBrush() {
  static Brush brush = [] {
    auto color = winrt::Windows::UI::Color{0xFF, 0x99, 0x99, 0x99};
    return SolidColorBrush(color).as<Brush>();
  }();
  return brush;
}

Brush GridBrush() {
  static Brush brush = [] {
    auto color = winrt::Windows::UI::Color{0x28, 0x99, 0x99, 0x99};
    return SolidColorBrush(color).as<Brush>();
  }();
  return brush;
}

}  // namespace

ChartControl::ChartControl() {
  // The canvas is the plot surface; series polylines and rebuilt
  // decoration are all positioned in absolute control coordinates.
  SizeChanged([this](winrt::Windows::Foundation::IInspectable const&,
                     SizeChangedEventArgs const&) {
    static_built_ = false;
    Geometry geometry = ComputeGeometry();
    RebuildStatic(geometry);
    UpdateSeriesPolylines(geometry);
  });
}

void ChartControl::set_title(std::string title) {
  title_ = std::move(title);
  static_built_ = false;
  RebuildStatic(ComputeGeometry());
}

void ChartControl::set_series(std::vector<ChartSeriesSpec> specs) {
  Children().Clear();
  entries_.clear();
  static_built_ = false;
  for (auto& spec : specs) {
    Entry entry;
    entry.spec = std::move(spec);
    entry.polyline.StrokeThickness(1.8);
    auto fallback = winrt::Windows::UI::Color{0xFF, 0x99, 0x99, 0x99};
    entry.polyline.Stroke(SolidColorBrush(ParseColor(entry.spec.color, fallback)));
    entry.cursor_dot.Width(7);
    entry.cursor_dot.Height(7);
    entry.cursor_dot.Fill(entry.polyline.Stroke());
    Children().Append(entry.polyline);
    Children().Append(entry.cursor_dot);
    entry.cursor_dot.Visibility(Visibility::Collapsed);
    entries_.push_back(std::move(entry));
  }
  Geometry geometry = ComputeGeometry();
  RebuildStatic(geometry);
  UpdateSeriesPolylines(geometry);
}

void ChartControl::set_window(std::int64_t span_ns) {
  if (span_ns > 0) {
    span_ns_ = span_ns;
    Geometry geometry = ComputeGeometry();
    RebuildStatic(geometry);
    UpdateSeriesPolylines(geometry);
  }
}

void ChartControl::set_y_range(bool auto_scale, std::int64_t min, std::int64_t max) {
  auto_scale_ = auto_scale;
  y_min_ = min;
  y_max_ = max;
  Geometry geometry = ComputeGeometry();
  RebuildStatic(geometry);
  UpdateSeriesPolylines(geometry);
}

void ChartControl::set_thresholds(std::vector<ChartThreshold> thresholds) {
  thresholds_ = std::move(thresholds);
  static_built_ = false;
  RebuildStatic(ComputeGeometry());
}

void ChartControl::set_markers(std::vector<ChartMarker> markers) {
  markers_ = std::move(markers);
  static_built_ = false;
  RebuildStatic(ComputeGeometry());
}

ChartControl::Entry* ChartControl::Find(std::string const& id) {
  for (auto& entry : entries_) {
    if (entry.spec.id == id) {
      return &entry;
    }
  }
  return nullptr;
}

void ChartControl::append_batch(std::string const& series_id, rivet::Bytes const& batch) {
  Entry* entry = Find(series_id);
  if (entry == nullptr) {
    return;
  }
  rivet::chart::Batch decoded;
  try {
    decoded = rivet::chart::DecodeBatch(batch);
  } catch (std::runtime_error const&) {
    return;  // malformed batches must not take down the UI process
  }
  if (entry->model.ApplyBatch(decoded) == rivet::chart::SeriesModel::ApplyResult::gap && on_gap) {
    on_gap(series_id);
  }
  Geometry geometry = ComputeGeometry();
  RebuildStatic(geometry);
  UpdateSeriesPolylines(geometry);
}

void ChartControl::replace_series(std::string const& series_id,
                                  std::vector<rivet::chart::Sample> window,
                                  std::uint64_t watermark) {
  Entry* entry = Find(series_id);
  if (entry == nullptr) {
    return;
  }
  try {
    entry->model.ResetFromWindow(std::move(window), watermark);
  } catch (std::runtime_error const&) {
    return;
  }
  Geometry geometry = ComputeGeometry();
  RebuildStatic(geometry);
  UpdateSeriesPolylines(geometry);
}

void ChartControl::clear() {
  for (auto& entry : entries_) {
    entry.model.Clear();
  }
  Geometry geometry = ComputeGeometry();
  RebuildStatic(geometry);
  UpdateSeriesPolylines(geometry);
}

ChartControl::Geometry ChartControl::ComputeGeometry() const {
  Geometry geometry{};
  double width = static_cast<double>(ActualWidth());
  double height = static_cast<double>(ActualHeight());
  if (width <= kMarginLeft + kMarginRight || height <= kMarginTop + kMarginBottom) {
    return geometry;
  }
  geometry.left = kMarginLeft;
  geometry.top = kMarginTop;
  geometry.width = width - kMarginLeft - kMarginRight;
  geometry.height = height - kMarginTop - kMarginBottom;

  bool any = false;
  for (auto const& entry : entries_) {
    if (!entry.model.empty()) {
      geometry.newest = any ? std::max(geometry.newest, entry.model.newest_ts())
                            : entry.model.newest_ts();
      any = true;
    }
  }
  geometry.t_left = any ? geometry.newest - span_ns_ : 0;

  std::int64_t v_min = 0;
  std::int64_t v_max = 0;
  bool have = false;
  for (auto const& entry : entries_) {
    std::size_t start = entry.model.WindowStartNs(span_ns_);
    auto const* samples = entry.model.data();
    for (std::size_t i = start; i < entry.model.size(); ++i) {
      if (samples[i].ts_ns < geometry.t_left) {
        continue;
      }
      if (!have) {
        v_min = v_max = samples[i].value;
        have = true;
      } else {
        v_min = std::min(v_min, samples[i].value);
        v_max = std::max(v_max, samples[i].value);
      }
    }
  }
  if (!auto_scale_) {
    geometry.v_min = y_min_;
    geometry.v_max = y_max_;
  } else if (have && v_min == v_max) {
    geometry.v_min = v_min - 1;
    geometry.v_max = v_max + 1;
  } else if (have) {
    geometry.v_min = v_min;
    geometry.v_max = v_max;
  } else {
    geometry.v_min = -1;
    geometry.v_max = 1;
  }
  return geometry;
}

void ChartControl::RebuildStatic(Geometry const& geometry) {
  if (geometry.width <= 0 || geometry.height <= 0) {
    return;
  }
  if (static_built_ && geometry == last_geometry_) {
    return;
  }
  last_geometry_ = geometry;
  static_built_ = true;

  // Rebuild decoration while preserving the persistent series shapes that
  // set_series appended: collect them, clear, re-append, then append new
  // decoration below them.
  std::vector<Shapes::Polyline> polylines;
  std::vector<Shapes::Ellipse> dots;
  for (auto& entry : entries_) {
    polylines.push_back(entry.polyline);
    dots.push_back(entry.cursor_dot);
  }
  Children().Clear();
  for (auto& polyline : polylines) {
    Children().Append(polyline);
  }
  for (auto& dot : dots) {
    Children().Append(dot);
  }

  double v_range = static_cast<double>(geometry.v_max - geometry.v_min);
  auto ValueToY = [&](std::int64_t v) {
    return geometry.top +
           (1.0 - static_cast<double>(v - geometry.v_min) / (v_range > 0 ? v_range : 1.0)) *
               geometry.height;
  };

  auto AddLabel = [&](std::string const& text, double x, double y, bool right_align) {
    TextBlock label;
    label.Text(ToWide(text));
    label.FontSize(10);
    label.Foreground(DimBrush());
    Children().Append(label);
    label.Measure({1000, 1000});
    double width = label.DesiredSize().Width;
    Canvas::SetLeft(label, right_align ? x - width : x);
    Canvas::SetTop(label, y);
  };

  std::string const unit = entries_.empty() ? std::string() : entries_.front().spec.unit;
  double v_step = NiceStep(v_range / 2.618);
  for (double v = std::ceil(static_cast<double>(geometry.v_min) / v_step) * v_step;
       v <= static_cast<double>(geometry.v_max) + v_step * 0.001; v += v_step) {
    double y = ValueToY(static_cast<std::int64_t>(v));
    if (y < geometry.top || y > geometry.top + geometry.height) {
      continue;
    }
    Line line;
    line.X1(geometry.left);
    line.Y1(y);
    line.X2(geometry.left + geometry.width);
    line.Y2(y);
    line.Stroke(GridBrush());
    line.StrokeThickness(1);
    Children().Append(line);
    AddLabel(FormatScaled(static_cast<std::int64_t>(v), unit), geometry.left - 6, y - 7, true);
  }

  double t_step = NiceStep(static_cast<double>(span_ns_) / 2.618);
  for (double t = std::ceil(static_cast<double>(geometry.t_left) / t_step) * t_step;
       t <= static_cast<double>(geometry.newest) + t_step * 0.001; t += t_step) {
    double x = geometry.left +
               (t - static_cast<double>(geometry.t_left)) /
                   static_cast<double>(std::max<std::int64_t>(span_ns_, 1)) * geometry.width;
    Line line;
    line.X1(x);
    line.Y1(geometry.top);
    line.X2(x);
    line.Y2(geometry.top + geometry.height);
    line.Stroke(GridBrush());
    line.StrokeThickness(1);
    Children().Append(line);
    std::int64_t age = static_cast<std::int64_t>(
        std::round(static_cast<double>(geometry.newest - static_cast<std::int64_t>(t)) / t_step) *
        t_step);
    AddLabel(age == 0 ? "now" : ("-" + FormatDurationNs(age)), x + 3,
             geometry.top + geometry.height + 6, false);
  }

  auto fallback = winrt::Windows::UI::Color{0xFF, 0x99, 0x99, 0x99};
  for (auto const& threshold : thresholds_) {
    double y = ValueToY(threshold.value);
    if (y < geometry.top || y > geometry.top + geometry.height) {
      continue;
    }
    Line line;
    line.X1(geometry.left);
    line.Y1(y);
    line.X2(geometry.left + geometry.width);
    line.Y2(y);
    line.Stroke(SolidColorBrush(ParseColor(threshold.color, fallback)));
    line.StrokeThickness(1);
    auto dash = line.StrokeDashArray();
    dash.Append(6.0);
    dash.Append(4.0);
    Children().Append(line);
    if (!threshold.label.empty()) {
      AddLabel(threshold.label, geometry.left + geometry.width - 4, y - 16, true);
    }
  }

  for (auto const& marker : markers_) {
    if (marker.ts_ns < geometry.t_left || marker.ts_ns > geometry.newest) {
      continue;
    }
    double x = geometry.left +
               static_cast<double>(marker.ts_ns - geometry.t_left) /
                   static_cast<double>(std::max<std::int64_t>(span_ns_, 1)) * geometry.width;
    Line line;
    line.X1(x);
    line.Y1(geometry.top);
    line.X2(x);
    line.Y2(geometry.top + geometry.height);
    line.Stroke(DimBrush());
    line.StrokeThickness(1);
    Children().Append(line);
    Polygon tick;
    tick.Points().Append(winrt::Windows::Foundation::Point(
        static_cast<float>(x - 4), static_cast<float>(geometry.top)));
    tick.Points().Append(winrt::Windows::Foundation::Point(
        static_cast<float>(x + 4), static_cast<float>(geometry.top)));
    tick.Points().Append(winrt::Windows::Foundation::Point(
        static_cast<float>(x), static_cast<float>(geometry.top + 7)));
    tick.Fill(DimBrush());
    Children().Append(tick);
  }

  AutomationProperties::SetName(*this, ToWide(title_.empty() ? "rivet chart" : title_));
}

void ChartControl::UpdateSeriesPolylines(Geometry const& geometry) {
  if (geometry.width <= 0 || geometry.height <= 0) {
    return;
  }
  double v_range = static_cast<double>(geometry.v_max - geometry.v_min);
  for (auto& entry : entries_) {
    auto points = entry.polyline.Points();
    points.Clear();
    std::size_t start = entry.model.WindowStartNs(span_ns_);
    auto const* samples = entry.model.data();
    for (std::size_t i = start; i < entry.model.size(); ++i) {
      if (samples[i].ts_ns < geometry.t_left) {
        continue;
      }
      double x = geometry.left +
                 static_cast<double>(samples[i].ts_ns - geometry.t_left) /
                     static_cast<double>(std::max<std::int64_t>(span_ns_, 1)) * geometry.width;
      double y = geometry.top +
                 (1.0 - static_cast<double>(samples[i].value - geometry.v_min) /
                            (v_range > 0 ? v_range : 1.0)) *
                     geometry.height;
      points.Append(winrt::Windows::Foundation::Point(
          static_cast<float>(x), static_cast<float>(y)));
    }
  }

  // Keep the semantic value current for UI Automation.
  std::string description = title_.empty() ? "chart" : title_;
  for (auto const& entry : entries_) {
    description += "; " + entry.spec.label + " latest ";
    description += entry.model.size() > 0
                       ? FormatScaled(entry.model.data()[entry.model.size() - 1].value,
                                      entry.spec.unit)
                       : "n/a";
  }
  AutomationProperties::SetFullDescription(*this, ToWide(description));
}

}  // namespace rivet::win_ui
