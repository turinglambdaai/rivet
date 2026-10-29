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
   **Start the event ticker from a Rivet RPC handler after `serve` starts**;
   drain and emit at UI cadence (30–60 Hz). See the thread ownership rule below.
4. Expose a window RPC for initial paint and gap recovery.
5. In the host, feed batches to the widget on the main thread and wire the
   widget's gap callback to the window RPC.

## Event ticker thread ownership

Rivet currently binds its event emitter using a Racket thread parameter while
serving the RVT1 connection. **A thread created before `serve`, or created
independently of the server reader, cannot call `define-event` functions,**
even while a server is connected. Thread parameters are inherited at thread
creation, not discovered dynamically from a running server. Unlike synchronized
chart ring appends, event emission requires this inherited connection context.

Start the ticker from an RPC invoked by the connected host (for example,
`start-chart-stream` during native view setup). The handler is a child of
the server reader and its own `thread` children inherit the emitter:

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

The product must define `emit-current-chart-batches!`, provide a stop/cancel
policy for its ticker, and invoke `start-chart-stream` from the native host
after connecting. Do not assume a pre-started engine/timer thread has emitter
access. If it must remain independent, it can append to the synchronized ring
and leave event publishing to the server-owned ticker.

This is a **thread-scoped API**, not a process-wide broadcast registry; it
does not select arbitrarily among multiple `serve` instances. An explicit
cross-thread event-handle API would be a separate lifetime/backpressure design.
