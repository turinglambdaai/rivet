# Taskboard performance contract

Performance is part of the reference architecture, so its boundaries are
written down before screenshots or one-off measurements are treated as proof.
These are regression budgets, not benchmark claims about all hardware.

| Scenario | Start | Stop | Release-build budget |
| --- | --- | --- | ---: |
| Backend ready | Start the embedded Racket backend | Receive the RVT1 Hello frame | 5,000 ms |
| Generate 1,000 | Send `generate-demo-tasks(1000)` | Decode the terminal response containing 1,000 records | 5,000 ms |
| Native cold start | Launch the packaged process | Task list accepts keyboard focus and shows initial data | 5,000 ms p95 |
| Native 1,000-row view | Activate **Generate 1,000** | Last row is selectable and **Cancel** is hidden | 5,000 ms p95 |

`tests/backend.rkt` enforces the first two boundaries with the real RVT1 server.
The limits deliberately leave headroom for shared CI runners while catching an
accidental blocking call, unbounded workload, or wire-format regression.

For native evidence, measure a packaged Release build on an otherwise idle
machine. Run ten cold process launches and ten 1,000-row generations, discard
the first warm-up result from each set, and record the p50 and p95 together with
the OS version, CPU, architecture, Racket version, and Rivet commit. A platform
result is not a baseline until the repository contains its measurement command
or automation output; visual inspection alone does not satisfy this contract.

The 1,000-row operation is intentionally bounded. If a real product needs much
larger collections, add native virtualization or pagination and establish a
new product-specific budget instead of weakening this example's limit.
