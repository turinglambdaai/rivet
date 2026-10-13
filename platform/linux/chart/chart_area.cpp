#include "chart_area.hpp"

#include <pango/pangocairo.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>

namespace rivet::ui {
namespace {

constexpr int kMarginLeft = 68;
constexpr int kMarginRight = 18;
constexpr int kMarginTop = 16;
constexpr int kMarginBottom = 30;
constexpr int kLegendRow = 22;
constexpr double kNiceLineRatio = 2.618;  // grid density target

std::string FormatScaled(std::int64_t value, std::string const& unit) {
  char buf[64];
  double const magnitude = std::abs(static_cast<double>(value));
  if (magnitude >= 1e9) {
    std::snprintf(buf, sizeof(buf), "%.2fG", static_cast<double>(value) / 1e9);
  } else if (magnitude >= 1e6) {
    std::snprintf(buf, sizeof(buf), "%.2fM", static_cast<double>(value) / 1e6);
  } else if (magnitude >= 1e3) {
    std::snprintf(buf, sizeof(buf), "%.2fk", static_cast<double>(value) / 1e3);
  } else if (magnitude >= 1) {
    std::snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(value));
  } else if (magnitude > 0) {
    std::snprintf(buf, sizeof(buf), "%.0fn", static_cast<double>(value) * 1e0);
  } else {
    std::snprintf(buf, sizeof(buf), "0");
  }
  return unit.empty() ? std::string(buf) : std::string(buf) + unit;
}

std::string FormatDurationNs(std::int64_t ns) {
  char buf[64];
  double const magnitude = std::abs(static_cast<double>(ns));
  if (magnitude >= 1e9) {
    std::snprintf(buf, sizeof(buf), "%.2fs", static_cast<double>(ns) / 1e9);
  } else if (magnitude >= 1e6) {
    std::snprintf(buf, sizeof(buf), "%.1fms", static_cast<double>(ns) / 1e6);
  } else if (magnitude >= 1e3) {
    std::snprintf(buf, sizeof(buf), "%.0fµs", static_cast<double>(ns) / 1e3);
  } else {
    std::snprintf(buf, sizeof(buf), "%lldns", static_cast<long long>(ns));
  }
  return buf;
}

// Rounded to 1/2/5 x 10^k so grid labels stay short.
double NiceStep(double raw) {
  if (raw <= 0) {
    return 1.0;
  }
  double const exponent = std::floor(std::log10(raw));
  double const fraction = raw / std::pow(10.0, exponent);
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

struct PlotRect {
  double left;
  double top;
  double width;
  double height;
};

}  // namespace

ChartArea::ChartArea() {
  widget_ = gtk_drawing_area_new();
  g_object_ref_sink(widget_);
  gtk_widget_set_size_request(widget_, 320, 180);
  gtk_widget_set_hexpand(widget_, TRUE);
  gtk_widget_set_vexpand(widget_, TRUE);
  gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(widget_), &ChartArea::Draw, this, nullptr);

  auto* motion = gtk_event_controller_motion_new();
  g_signal_connect(motion, "motion", G_CALLBACK(&ChartArea::OnMotion), this);
  g_signal_connect(motion, "leave", G_CALLBACK(&ChartArea::OnLeave), this);
  gtk_widget_add_controller(widget_, motion);

  gtk_accessible_update_property(GTK_ACCESSIBLE(widget_),
                                 GTK_ACCESSIBLE_PROPERTY_LABEL, "rivet chart", -1);
}

ChartArea::~ChartArea() {
  g_object_unref(widget_);
}

void ChartArea::set_title(std::string title) {
  title_ = std::move(title);
  RequestDraw();
}

void ChartArea::set_series(std::vector<ChartSeriesSpec> specs) {
  entries_.clear();
  entries_.reserve(specs.size());
  for (auto& spec : specs) {
    Entry entry{std::move(spec), rivet::chart::SeriesModel{}};
    entries_.push_back(std::move(entry));
  }
  RequestDraw();
}

void ChartArea::set_window(std::int64_t span_ns) {
  if (span_ns > 0) {
    span_ns_ = span_ns;
    RequestDraw();
  }
}

void ChartArea::set_y_range(bool auto_scale, std::int64_t min, std::int64_t max) {
  auto_scale_ = auto_scale;
  y_min_ = min;
  y_max_ = max;
  RequestDraw();
}

void ChartArea::set_thresholds(std::vector<ChartThreshold> thresholds) {
  thresholds_ = std::move(thresholds);
  RequestDraw();
}

void ChartArea::set_markers(std::vector<ChartMarker> markers) {
  markers_ = std::move(markers);
  RequestDraw();
}

void ChartArea::clear() {
  for (auto& entry : entries_) {
    entry.model.Clear();
  }
  RequestDraw();
}

ChartArea::Entry* ChartArea::Find(std::string const& id) {
  for (auto& entry : entries_) {
    if (entry.spec.id == id) {
      return &entry;
    }
  }
  return nullptr;
}

void ChartArea::append_batch(std::string const& series_id, rivet::Bytes const& batch) {
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
  auto const result = entry->model.ApplyBatch(decoded);
  if (result == rivet::chart::SeriesModel::ApplyResult::gap && on_gap) {
    on_gap(series_id);
  }
  RequestDraw();
}

void ChartArea::replace_series(std::string const& series_id,
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
  RequestDraw();
}

void ChartArea::RequestDraw() {
  if (widget_ != nullptr) {
    gtk_widget_queue_draw(widget_);
  }
}

void ChartArea::OnMotion(GtkEventControllerMotion*, double x, double y, gpointer user_data) {
  auto* self = static_cast<ChartArea*>(user_data);
  self->have_cursor_ = true;
  self->cursor_x_ = x;
  self->cursor_y_ = y;
  self->RequestDraw();
}

void ChartArea::OnLeave(GtkEventControllerMotion*, gpointer user_data) {
  auto* self = static_cast<ChartArea*>(user_data);
  self->have_cursor_ = false;
  if (self->on_cursor) {
    self->on_cursor(std::string());
  }
  self->RequestDraw();
}

void ChartArea::Draw(GtkDrawingArea*, cairo_t* cr, int width, int height, gpointer user_data) {
  auto* self = static_cast<ChartArea*>(user_data);
  if (width <= kMarginLeft + kMarginRight || height <= kMarginTop + kMarginBottom) {
    return;
  }

  GdkRGBA fg{};
  gtk_widget_get_color(self->widget_, &fg);
  GdkRGBA grid{fg.red, fg.green, fg.blue, fg.alpha * 0.18f};
  GdkRGBA dim{fg.red, fg.green, fg.blue, fg.alpha * 0.6f};

  PlotRect plot{static_cast<double>(kMarginLeft),
                static_cast<double>(kMarginTop + kLegendRow),
                static_cast<double>(width - kMarginLeft - kMarginRight),
                static_cast<double>(height - kMarginTop - kMarginBottom - kLegendRow)};

  // Time domain: the newest sample across all series anchors the right edge.
  std::int64_t newest = 0;
  bool any = false;
  for (auto const& entry : self->entries_) {
    if (!entry.model.empty()) {
      newest = any ? std::max(newest, entry.model.newest_ts()) : entry.model.newest_ts();
      any = true;
    }
  }
  std::int64_t const t_left = any ? newest - self->span_ns_ : 0;

  auto TimeToX = [&](std::int64_t t) {
    double const span = static_cast<double>(self->span_ns_);
    double const offset = static_cast<double>(t - t_left);
    return plot.left + (span > 0 ? offset / span * plot.width : plot.width);
  };

  // Value domain over the visible window.
  std::int64_t v_min = 0;
  std::int64_t v_max = 0;
  bool have_values = false;
  for (auto const& entry : self->entries_) {
    std::size_t const start = entry.model.WindowStartNs(self->span_ns_);
    auto const* samples = entry.model.data();
    for (std::size_t i = start; i < entry.model.size(); ++i) {
      if (samples[i].ts_ns < t_left) {
        continue;
      }
      if (!have_values) {
        v_min = v_max = samples[i].value;
        have_values = true;
      } else {
        v_min = std::min(v_min, samples[i].value);
        v_max = std::max(v_max, samples[i].value);
      }
    }
  }
  if (!self->auto_scale_) {
    v_min = self->y_min_;
    v_max = self->y_max_;
  } else if (have_values && v_min == v_max) {
    v_min -= 1;
    v_max += 1;
  } else if (!have_values) {
    v_min = -1;
    v_max = 1;
  }
  double const v_range = static_cast<double>(v_max - v_min);
  auto ValueToY = [&](std::int64_t v) {
    return plot.top + (1.0 - static_cast<double>(v - v_min) / (v_range > 0 ? v_range : 1.0)) *
                          plot.height;
  };

  cairo_set_line_width(cr, 1.0);
  cairo_set_source_rgba(cr, grid.red, grid.green, grid.blue, grid.alpha);

  // Horizontal grid + y labels.
  PangoLayout* y_layout = pango_cairo_create_layout(cr);
  pango_layout_set_width(y_layout, (kMarginLeft - 8) * PANGO_SCALE);
  double const step = NiceStep(v_range / kNiceLineRatio);
  double v = std::ceil(static_cast<double>(v_min) / step) * step;
  for (; v <= static_cast<double>(v_max) + step * 0.001; v += step) {
    double const y = ValueToY(static_cast<std::int64_t>(v));
    if (y < plot.top || y > plot.top + plot.height) {
      continue;
    }
    cairo_move_to(cr, plot.left, y);
    cairo_line_to(cr, plot.left + plot.width, y);
    cairo_stroke(cr);
    std::string const unit = self->entries_.empty() ? std::string() : self->entries_.front().spec.unit;
    pango_layout_set_text(y_layout, FormatScaled(static_cast<std::int64_t>(v), unit).c_str(), -1);
    cairo_set_source_rgba(cr, dim.red, dim.green, dim.blue, dim.alpha);
    cairo_move_to(cr, 4, y - 7);
    pango_cairo_show_layout(cr, y_layout);
    cairo_set_source_rgba(cr, grid.red, grid.green, grid.blue, grid.alpha);
  }

  // Time grid + x labels.
  PangoLayout* x_layout = pango_cairo_create_layout(cr);
  double const t_step = NiceStep(static_cast<double>(self->span_ns_) / kNiceLineRatio);
  double t = std::ceil(static_cast<double>(t_left) / t_step) * t_step;
  for (; t <= static_cast<double>(newest) + t_step * 0.001; t += t_step) {
    double const x = TimeToX(static_cast<std::int64_t>(t));
    cairo_move_to(cr, x, plot.top);
    cairo_line_to(cr, x, plot.top + plot.height);
    cairo_stroke(cr);
    // Label as negative offsets from "now", rounded to the grid step so
    // labels stay anchored (-20s, -10s) instead of drifting with the
    // sample clock; a rolling chart has no wall-clock meaning.
    std::int64_t const age = static_cast<std::int64_t>(
        std::round(static_cast<double>(newest - static_cast<std::int64_t>(t)) / t_step) * t_step);
    std::string const label = age == 0 ? "now" : ("-" + FormatDurationNs(age));
    pango_layout_set_text(x_layout, label.c_str(), -1);
    cairo_set_source_rgba(cr, dim.red, dim.green, dim.blue, dim.alpha);
    cairo_move_to(cr, x + 3, plot.top + plot.height + 6);
    pango_cairo_show_layout(cr, x_layout);
    cairo_set_source_rgba(cr, grid.red, grid.green, grid.blue, grid.alpha);
  }

  // Thresholds: dashed lines with their labels at the right edge.
  for (auto const& threshold : self->thresholds_) {
    double const y = ValueToY(threshold.value);
    if (y < plot.top || y > plot.top + plot.height) {
      continue;
    }
    double dashes[] = {6.0, 4.0};
    cairo_set_dash(cr, dashes, 2, 0.0);
    GdkRGBA color{};
    if (!gdk_rgba_parse(&color, threshold.color.c_str())) {
      color = dim;
    }
    cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha);
    cairo_move_to(cr, plot.left, y);
    cairo_line_to(cr, plot.left + plot.width, y);
    cairo_stroke(cr);
    cairo_set_dash(cr, nullptr, 0, 0.0);
    if (!threshold.label.empty()) {
      pango_layout_set_text(x_layout, threshold.label.c_str(), -1);
      cairo_move_to(cr, plot.left + plot.width - 6, y - 16);
      pango_cairo_show_layout(cr, x_layout);
    }
  }

  cairo_rectangle(cr, plot.left, plot.top, plot.width, plot.height);
  cairo_clip(cr);

  // Markers: vertical lines with a tick at the top.
  for (auto const& marker : self->markers_) {
    if (marker.ts_ns < t_left || marker.ts_ns > newest) {
      continue;
    }
    double const x = TimeToX(marker.ts_ns);
    cairo_set_source_rgba(cr, dim.red, dim.green, dim.blue, dim.alpha * 0.9);
    cairo_move_to(cr, x, plot.top);
    cairo_line_to(cr, x, plot.top + plot.height);
    cairo_stroke(cr);
    cairo_move_to(cr, x - 4, plot.top);
    cairo_line_to(cr, x + 4, plot.top);
    cairo_line_to(cr, x, plot.top + 7);
    cairo_close_path(cr);
    cairo_fill(cr);
  }

  // Series polylines with their cursor dots.
  cairo_set_line_width(cr, 1.8);
  cairo_set_antialias(cr, CAIRO_ANTIALIAS_GOOD);
  std::string cursor_readout;
  for (auto const& entry : self->entries_) {
    GdkRGBA color{};
    if (!gdk_rgba_parse(&color, entry.spec.color.c_str())) {
      color = dim;
    }
    cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha);

    std::size_t const start = entry.model.WindowStartNs(self->span_ns_);
    auto const* samples = entry.model.data();
    bool pen_down = false;
    for (std::size_t i = start; i < entry.model.size(); ++i) {
      if (samples[i].ts_ns < t_left) {
        continue;
      }
      double const x = TimeToX(samples[i].ts_ns);
      double const y = ValueToY(samples[i].value);
      if (!pen_down) {
        cairo_move_to(cr, x, y);
        pen_down = true;
      } else {
        cairo_line_to(cr, x, y);
      }
    }
    if (pen_down) {
      cairo_stroke(cr);
    }

    if (self->have_cursor_ && entry.model.size() > start) {
      // Nearest sample to the cursor time position.
      double const cursor_t =
          t_left + (self->cursor_x_ - plot.left) / plot.width * static_cast<double>(self->span_ns_);
      auto const* base = samples + start;
      std::size_t const count = entry.model.size() - start;
      std::size_t const pos = static_cast<std::size_t>(
          std::lower_bound(base, base + count, cursor_t,
                           [](rivet::chart::Sample const& s, double target) {
                             return static_cast<double>(s.ts_ns) < target;
                           }) - base);
      std::size_t pick = pos;
      if (pos > 0 && (pos >= count ||
                      std::abs(static_cast<double>(base[pos].ts_ns) - cursor_t) >
                          std::abs(static_cast<double>(base[pos - 1].ts_ns) - cursor_t))) {
        pick = pos - 1;
      }
      if (pick < count) {
        double const x = TimeToX(base[pick].ts_ns);
        double const y = ValueToY(base[pick].value);
        cairo_set_line_width(cr, 1.0);
        cairo_arc(cr, x, y, 3.5, 0.0, 2.0 * M_PI);
        cairo_fill(cr);
        cairo_set_line_width(cr, 1.8);
        if (cursor_readout.empty()) {
          cursor_readout = FormatDurationNs(newest - base[pick].ts_ns) + " ago";
        }
        cursor_readout += "  " + entry.spec.label + " " +
                          FormatScaled(base[pick].value, entry.spec.unit);
      }
    }
  }

  // Cursor crosshair on top of the polylines.
  if (self->have_cursor_) {
    cairo_set_source_rgba(cr, dim.red, dim.green, dim.blue, dim.alpha * 0.7);
    cairo_set_line_width(cr, 1.0);
    double dashes[] = {3.0, 3.0};
    cairo_set_dash(cr, dashes, 2, 0.0);
    cairo_move_to(cr, self->cursor_x_, plot.top);
    cairo_line_to(cr, self->cursor_x_, plot.top + plot.height);
    cairo_stroke(cr);
    cairo_set_dash(cr, nullptr, 0, 0.0);
  }

  cairo_reset_clip(cr);

  // Legend above the plot: color chip, label, latest value.
  PangoLayout* legend_layout = pango_cairo_create_layout(cr);
  double legend_x = plot.left;
  double const legend_y = kMarginTop - 2;
  for (auto const& entry : self->entries_) {
    GdkRGBA color{};
    if (!gdk_rgba_parse(&color, entry.spec.color.c_str())) {
      color = dim;
    }
    cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha);
    cairo_rectangle(cr, legend_x, legend_y + 5, 10, 10);
    cairo_fill(cr);
    legend_x += 15;
    std::string text = entry.spec.label;
    if (entry.model.size() > 0) {
      auto const& latest = entry.model.data()[entry.model.size() - 1];
      text += " " + FormatScaled(latest.value, entry.spec.unit);
    }
    pango_layout_set_text(legend_layout, text.c_str(), -1);
    cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, fg.alpha);
    cairo_move_to(cr, legend_x, legend_y);
    pango_cairo_show_layout(cr, legend_layout);
    int layout_width = 0;
    pango_layout_get_pixel_size(legend_layout, &layout_width, nullptr);
    legend_x += layout_width + 18;
  }

  if (!self->title_.empty()) {
    pango_layout_set_text(legend_layout, self->title_.c_str(), -1);
    int title_width = 0;
    pango_layout_get_pixel_size(legend_layout, &title_width, nullptr);
    cairo_set_source_rgba(cr, dim.red, dim.green, dim.blue, dim.alpha);
    cairo_move_to(cr, plot.left + plot.width - title_width, legend_y);
    pango_cairo_show_layout(cr, legend_layout);
  }

  g_object_unref(y_layout);
  g_object_unref(x_layout);
  g_object_unref(legend_layout);

  // Keep the semantic value current for AT-SPI and the on_cursor host hook.
  std::string description = self->title_.empty() ? "chart" : self->title_;
  for (auto const& entry : self->entries_) {
    description += "; " + entry.spec.label + " latest ";
    description += entry.model.size() > 0
                       ? FormatScaled(entry.model.data()[entry.model.size() - 1].value,
                                      entry.spec.unit)
                       : "n/a";
  }
  gtk_accessible_update_property(GTK_ACCESSIBLE(self->widget_),
                                 GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description.c_str(), -1);
  if (self->have_cursor_ && self->on_cursor) {
    self->on_cursor(cursor_readout);
  }
}

}  // namespace rivet::ui
