# Native protocol fuzzing

Rivet includes an opt-in libFuzzer harness for the native RVT1 value and frame decoders. Normal runtime builds do not enable fuzzing or sanitizer instrumentation.

## Requirements

- Clang with libFuzzer support
- CMake 3.20 or newer
- Python 3 for generating the initial seed corpus from Rivet's shared protocol vectors

## Build

```sh
CC=clang CXX=clang++ cmake -S runtime -B build/fuzz \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DRIVET_BUILD_TESTS=OFF \
  -DRIVET_BUILD_FUZZERS=ON
cmake --build build/fuzz --target rivet_protocol_fuzz
```

When `RIVET_BUILD_FUZZERS=ON`, the native protocol implementation and harness are compiled with libFuzzer coverage instrumentation plus AddressSanitizer and UndefinedBehaviorSanitizer. CMake rejects non-Clang compilers for this mode instead of silently creating a non-fuzzing binary.

## Seed corpus

Rivet's existing cross-language golden vectors are the canonical starting corpus:

```sh
python3 runtime/fuzz/seed_corpus.py build/fuzz/corpus
```

The script writes every valid and invalid value/frame vector as a separate binary corpus entry. This keeps regression vectors and fuzz seeds aligned without committing duplicate binary fixtures.

## Run

A short local smoke run:

```sh
mkdir -p build/fuzz/artifacts
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  build/fuzz/rivet_protocol_fuzz build/fuzz/corpus \
  -runs=20000 -seed=12345 -max_len=65536 -timeout=5 -rss_limit_mb=2048 \
  -print_final_stats=1 -artifact_prefix=build/fuzz/artifacts/
```

Keep the seed when reproducing a CI failure. libFuzzer's mutation sequence is deterministic for a fixed executable, starting corpus, options, and `-seed`, so the seed printed by the CI job is part of the failure record. For a longer campaign, omit `-runs` or replace it with a larger budget. Keep the corpus directory between runs so newly discovered coverage-producing inputs are retained.

The harness feeds every input to both native decoder surfaces:

- `decode_value`, followed by canonical encode/decode stability checks when parsing succeeds;
- `read_frame`, followed by write/read stability checks when parsing succeeds.

Parser exceptions for malformed input are expected. Crashes, sanitizer findings, timeouts, or failures of a successful decode to round-trip canonically are treated as bugs.

## CI

The `Protocol Fuzz Smoke` workflow builds the harness on Ubuntu with Clang, derives seeds from `tests/protocol-golden.txt`, and executes a bounded 20,000-run smoke campaign on every pull request and `main` push. The libFuzzer seed is derived deterministically from the GitHub Actions run id, so each CI run explores a different mutation sequence while remaining reproducible from its log.

CI writes crash, timeout, and OOM reproducer inputs to a dedicated libFuzzer artifact directory. If fuzzing fails, the job prints each reproducer's SHA-256 and complete hexadecimal payload before returning the original libFuzzer exit status. That makes a failed CI run self-contained: reconstruct the bytes from the logged hex, rebuild the same revision, and rerun the harness with the printed seed and options.

This smoke campaign is intentionally short enough for normal CI; longer fuzz campaigns can use the same target and corpus without changing production code.
