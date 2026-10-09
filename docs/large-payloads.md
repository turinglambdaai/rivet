# Large payloads, pagination, and progress

RVT1 gives a single frame 64 MiB and a 2^18 value-node budget. That is
deliberately generous for ordinary app traffic, and deliberately finite:
real workspace data — semantic diffs over an OEM delivery, a package tree
with tens of thousands of identifiables — will not fit in one response and
should not. This page is the convention layer for shapes that stay inside
the budget on real data.

## Report-shaped RPCs: paginate

Any RPC whose result is a list that grows with input size (diff findings,
impact reports, search hits) should return one page, not the whole list:

```racket
(define-record Page
  ([items : (List DiffEntry)]
   [total : Int64]
   [cursor : (Optional String)]))

(define-rpc (diff-workspaces [cursor : (Optional String)]
                             [limit : Int64]
                             : Page)
  ...)
```

Conventions:

- **Cursor, not offset.** A cursor is opaque to the host (a serialized
  position); offsets silently corrupt when the underlying data changes
  between pages. First request passes `null`; every response either
  carries the next cursor or a `null` cursor to mark the end.
- **`limit` is a host-controlled ceiling**, validated by the backend
  (cap it — a host bug asking for ten million items should fail closed,
  not OOM the frame).
- **`total` is advisory.** Hosts use it for progress hints ("showing 200
  of 14 632"), never for layout invariants.
- Records already type all of this — the `Page` record above is an ordinary
  `define-record` in your backend; no special wire support is needed.

The autarx workbench is the reference consumer: `diff_workspaces` and
`impact_for_ecu` move to this shape as real deliveries exceed fixture
scale.

## Tree-shaped RPCs: window the children

A tree whose per-node child count is unbounded (an ARXML package holding
tens of thousands of identifiables) should never be returned whole. The
convention:

- A load RPC returns **nodes with stable ids and child counts**, not the
  recursively expanded tree:

```racket
(define-record TreeNode
  ([id : String]
   [label : String]
   [child-count : Int64]))

(define-rpc (load-package [package-id : String] : (List TreeNode))
  ...)

(define-rpc (children [node-id : String]
                      [cursor : (Optional String)]
                      [limit : Int64]
                      : Page)
  ...)
```

- **Stable ids are the contract.** Hosts virtualize on them (SwiftUI
  `List` lazy rows, WinUI `ItemsRepeater` chunking); an id must resolve to
  the same node across a session.
- **`child-count` drives the expand affordance** (chevron with a count, a
  spinner while a page loads) without materializing grandchildren.
- Children use the same page shape as reports — same cursor discipline,
  same fail-closed limit cap.

A dedicated `Tree` wire type (child counts without list materialization in
one frame) is deliberately not built yet: the convention above already
bounds every frame, and a wire type should wait until a second consumer
beyond autarx has stress-tested the convention.

## Progress events: typed records, not strings

Long operations (indexing a 10M-line delivery) should report progress with
a record event, so hosts render determinate progress instead of parsing
strings:

```racket
(define-record Progress
  ([label : String]      ;; "Indexing ECUC containers"
   [fraction : Float64])) ;; 0.0 .. 1.0; a sentinel like -1 marks indeterminate

(define-event progress : Progress)
```

- `fraction` is a `Float64`, not a percent string; hosts multiply by 100
  if they want percent text.
- Define the record in your backend and the generated Swift/C++/Kotlin
  clients decode it structurally — no per-app parsing, no stringly-typed
  `"indexing 42%"` smuggling.

**Cancellation is a deliberate gap.** RVT1 carries `message:cancel`, but
`define-rpc` handlers have no cooperative cancellation check today; a
handler that loops over a big workspace cannot observe a cancel request.
The backend-side convention for now: chunk long work into page-sized
batches across separate RPC calls (the pagination shape above), so each
call is short and cancellation is simply "stop asking for pages." A
first-class `(cancel-requested?)` check inside handlers will be designed
together with the first consumer that genuinely needs mid-call cancel.

## Frame budget reminders

- A single response must stay under 64 MiB and 2^18 value nodes —
  validate page sizes, don't trust them.
- `Bytes` payloads (images, exports) ride outside the JSON value tree but
  still count against the frame; stream them in pages or via a file the
  host reads.
- When a host genuinely needs "everything", iterating cursor pages
  end-to-end is the supported path; it is fast (no UI work per page) and
  bounded per frame.
