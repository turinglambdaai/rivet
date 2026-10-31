# Real-time chart series

Rivet products render live time-series (sync convergence, engine telemetry,
simulator traces) through one shared data plane. This page is the
authoritative convention: the Racket state holder, the wire batch format,
and the native widget contract for all three desktop hosts.

The reference implementation lives in the Taskboard example: two synthetic
series stream from `examples/taskboard/app/backend.rkt` into the GTK4
`rivet::ui::ChartArea`, the SwiftUI `RivetChartView` (RivetUI), and the
WinUI 3 `rivet::win_ui::ChartControl`.

## Shape

- **State holder (Racket):** `rivet/chart` keeps one ring buffer per series.
  Samples are `(timestamp-ns . value)` pairs of exact integers. Timestamps
  are strictly increasing; values stay integers by design — ns offsets,
  ps offsets, ppm drift, and frame counts are integer-native, and Rivet's
  typed surface has no Float to lose precision through.
- **High-rate push (event):** a product declares
  `(define-event chart-batch : ChartBatchEnvelope)` where the record carries
  `[series : String] [batch : Bytes]`. A ticker drains the ring at UI cadence
  (30–60 Hz) and emits one batch per series; a batch carries only samples the
  host has not been sent yet.
- **Pull (RPC):** the window RPC returns the recent window plus the absolute
  watermark for the initial paint and for gap recovery.

## Batch format

Little-endian throughout. C++ decoder: `runtime/include/rivet/chart_batch.hpp`.
Swift decoder: `platform/macos/Sources/RivetUI`. The three implementations
(including `rivet/chart.rkt`) are pinned by shared golden bytes; changing the
layout is a versioned contract change in all three plus their test suites.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | magic `0x52564331` ("RVC1") |
| 4 | 4 | u32 sample count |
| 8 | 8 | i64 absolute index of the first sample |
| 16 | 16×n | per sample: i64 timestamp-ns, i64 value |

The absolute index is the total number of samples ever appended to the
series when the first batch sample was appended. Hosts keep a watermark
(the next index they expect); a batch starting beyond the watermark means
the Racket ring evicted undrained samples, and the host re-pulls the window
through its typed RPC instead of guessing.

## Throughput envelope

`benches/event-throughput.rkt` drives the real serve path over pipes
(Racket-side encode + frame + pipe write, client read-frame drain):

| Batch shape | Throughput |
| --- | ---: |
| 2-sample tick batch (48 B) | ~52 000 events/s |
| 16-sample drain batch (272 B — a 128 Hz stream drained at 30 Hz) | ~32 000 events/s |
| Full 16 384-sample window (256 KiB, recovery path) | ~70 events/s (~14 ms each) |

A two-series product load (batches at 30–60 Hz per series) sits three
orders of magnitude under capacity; the native redraw cadence is the
binding constraint, not the event channel. There is deliberately no
separate streaming transport.

## Host-side widgets

| Host | Widget | Notes |
| --- | --- | --- |
| Linux (GTK4) | `rivet::ui::ChartArea` in the platform library | `GtkDrawingArea` + Cairo; main-thread only |
| macOS / Apple | `RivetChartView` + `RivetChartModel` (RivetUI) | SwiftUI `Canvas`; model is `@MainActor` |
| Windows | `rivet::win_ui::ChartControl` | WinUI 3 `Canvas` of persistent `Polyline`s; UI thread only |

All three accept the same three inputs: series specs (id, label, color,
unit), decoration (threshold lines, event markers), and either decoded
batches or a full windowed replacement. RVT1 event callbacks arrive on the
reader thread — dispatch to the main loop / dispatcher queue before touching
the widget, exactly like every other Rivet event.

Features: multi-series rolling window, y autoscale or pinned range,
threshold lines with labels, event markers, hover cursor with per-series
readout, and an accessibility description that tracks the latest values
(exercised by the native UI suites).

## Integration checklist

1. Declare the envelope record and event; require `rivet/chart`.
2. Create series with a capacity covering your window at your sample rate
   (default 16 384 samples ≈ 2 min at 128 Hz).
3. Append from engine threads (`chart-series-append!` is synchronized).
   For a single active `serve`, independent engine threads may emit at UI
   cadence (30–60 Hz); with multiple concurrent servers, start a ticker from
   a specific connected RPC handler. See the ownership rule below.
4. Expose a window RPC for initial paint and gap recovery.
5. In the host, feed batches to the widget on the main thread and wire the
   widget's gap callback to the window RPC.

## Event ticker thread ownership

`emit-event!` prefers the server-owned thread parameter. When that parameter
is absent, an independent background thread may emit through the **unique**
active `serve` connection. This enables file watchers, chart engines and other
long-lived workers to publish progress without polling. The shared writer
channel still provides bounded backpressure; the fallback is not an
unrestricted process-wide broadcast.

When **multiple** `serve` instances exist in one Racket process, there is no
safe way for an unrelated worker to choose a recipient. In that case the
fallback raises `multiple Rivet servers are active` rather than leaking an
event to the wrong connection. The fallback is also removed on server exit.
A product managing multiple sessions should create its ticker within the
relevant server's connected RPC handler so that the thread-local emitter
unambiguously identifies the destination:

```racket
(define batch-ticker #f)
(define-rpc (start-chart-stream : Void)
  (unless batch-ticker
    (set! batch-ticker
          (thread
           (lambda ()
             (let loop ()
               (sleep 0.033)
               (emit-current-chart-batches!) ; product's typed chart-batch event
               (loop))))))
  (void))
```

The product must define `emit-current-chart-batches!` and provide a
stop/cancel policy for its ticker. Starting from a connected RPC handler is
the recommended choice for multi-server products. A single-server app may
instead use its existing independent engine thread; it must handle
disconnection and not keep emitting after `serve` exits.

This fallback is **single-server only**. It refuses ambiguous broadcast when
more than one `serve` instance is active. An explicit per-server event-handle
API would require a separately reviewed ownership and lifetime contract.
