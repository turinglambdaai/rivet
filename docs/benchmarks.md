# Embedded performance benchmarks

Rivet's first performance baseline measures the same native integration hosts used by the Windows and macOS embedded round-trip tests. The benchmark therefore includes the real in-process Racket CS runtime, RVT1 transport, native client, request lifecycle, and State synchronization path instead of measuring a detached codec microbenchmark.

## What is measured

The integration runner accepts an optional `--benchmark` flag. Benchmark mode reports one JSON object with schema version 1 and these metrics:

- `startup_ms`: elapsed time for `Backend::start()` / `EmbeddedRacketBackend.start()`, including Racket CS startup and the RVT1 Hello handshake;
- `rpc`: 1,000 sequential `increment(Int64) -> Int64` round trips after 50 warm-up calls;
- `state_get`: 1,000 sequential `$state/get` round trips;
- `state_set`: 500 sequential `$state/set` round trips, including the reserved `$state` Event that precedes each successful response.

Each operation group includes `iterations`, `total_ms`, and `us_per_operation`. Every timed operation still validates its result, so a fast but incorrect run fails instead of producing a number.

Example shape:

```json
{
  "schema_version": 1,
  "platform": "macos",
  "startup_ms": 42.5,
  "warmup_iterations": 50,
  "rpc": {
    "iterations": 1000,
    "total_ms": 120.0,
    "us_per_operation": 120.0
  },
  "state_get": {
    "iterations": 1000,
    "total_ms": 130.0,
    "us_per_operation": 130.0
  },
  "state_set": {
    "iterations": 500,
    "total_ms": 90.0,
    "us_per_operation": 180.0
  }
}
```

The numbers above illustrate the JSON schema only; they are not Rivet performance claims or release thresholds.

## Run on GitHub Actions

The existing `Embedded Roundtrip` workflow supports manual benchmark runs without changing pull-request behavior:

1. Open **Actions → Embedded Roundtrip → Run workflow**.
2. Select the revision to measure.
3. Enable **Run the real embedded integration hosts in benchmark mode**.
4. Read the JSON line from each platform's `Exercise embedded runtime` step.

Normal pull requests leave benchmark mode disabled and continue to run correctness-only round trips.

## Comparing results

Do not treat absolute timings from shared GitHub-hosted runners as hard pass/fail limits. Host load, virtualization, CPU generation, runner image, compiler version, and Racket version can move results independently of Rivet code.

For meaningful regression work:

- compare the same platform and architecture;
- use the same Racket, compiler, and runner image where possible;
- run several samples and compare distributions or medians rather than one measurement;
- use a dedicated or self-hosted machine before establishing release thresholds;
- keep `schema_version` in captured reports so future benchmark changes remain distinguishable.

The manual Actions mode is intended as a convenient baseline and investigation tool. Once enough history exists on stable hardware, selected metrics can be promoted to guarded regression thresholds without redesigning the integration harness.

## Scope

This first baseline focuses on runtime startup and request/State latency. Event-only throughput, concurrent RPC throughput, memory/RSS, and packaged application size are intentionally separate follow-ups because they need different sampling and interpretation. Keeping them separate avoids turning one benchmark number into an ambiguous mixture of unrelated costs.
