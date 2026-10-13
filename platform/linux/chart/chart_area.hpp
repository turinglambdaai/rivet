#pragma once

// GTK4 rolling-time-series chart for Rivet hosts.
//
// The widget is a GtkDrawingArea that renders every live series inside the
// configured time window, plus threshold lines, event markers, and a hover
// cursor with a per-series readout. Data arrives either as chart batches
// (append_batch, fed from the chart-batch event) or as a full window
// (replace_series, fed from the window RPC used for the initial paint and
// for gap recovery).
//
// All methods must be called on the GLib main loop, like every other GTK
// call; RVT1 event callbacks arrive on the reader thread and hosts must
// dispatch them with g_idle_add first (see examples/taskboard).

#include "rivet/chart_batch.hpp"

#include <gtk/gtk.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace rivet::ui {

struct ChartSeriesSpec final {
  std::string id;
  std::string label;
  std::string color;  // CSS color ("#3584e4")
  std::string unit;   // display unit appended to values ("ns", "ppm", "")
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

class ChartArea final {
 public:
  ChartArea();
  ~ChartArea();

  ChartArea(ChartArea const&) = delete;
  ChartArea& operator=(ChartArea const&) = delete;

  GtkWidget* widget() const { return widget_; }

  void set_title(std::string title);
  void set_series(std::vector<ChartSeriesSpec> specs);
  void set_window(std::int64_t span_ns);
  // auto_scale == false pins the y range; pass 0/0 to return to auto.
  void set_y_range(bool auto_scale, std::int64_t min, std::int64_t max);
  void set_thresholds(std::vector<ChartThreshold> thresholds);
  void set_markers(std::vector<ChartMarker> markers);

  void append_batch(std::string const& series_id, rivet::Bytes const& batch);
  void replace_series(std::string const& series_id,
                      std::vector<rivet::chart::Sample> window,
                      std::uint64_t watermark);
  void clear();

  // Fired on the main loop when a batch gap means the host must re-pull
  // that series through its window RPC.
  std::function<void(std::string const& series_id)> on_gap;
  // Fired on cursor motion/leave with the rendered readout (empty on leave)
  // so a host can show it in a status label or accessible region.
  std::function<void(std::string const& readout)> on_cursor;

 private:
  struct Entry final {
    ChartSeriesSpec spec;
    rivet::chart::SeriesModel model;
  };

  static void Draw(GtkDrawingArea* area, cairo_t* cr, int width, int height,
                   gpointer user_data);
  static void OnMotion(GtkEventControllerMotion* controller, double x, double y,
                       gpointer user_data);
  static void OnLeave(GtkEventControllerMotion* controller, gpointer user_data);

  Entry* Find(std::string const& id);
  void RequestDraw();

  GtkWidget* widget_{nullptr};
  std::vector<Entry> entries_;
  std::vector<ChartThreshold> thresholds_;
  std::vector<ChartMarker> markers_;
  std::string title_;
  std::int64_t span_ns_{30LL * 1000 * 1000 * 1000};
  bool auto_scale_{true};
  std::int64_t y_min_{0};
  std::int64_t y_max_{0};
  bool have_cursor_{false};
  double cursor_x_{0};
  double cursor_y_{0};
};

}  // namespace rivet::ui
