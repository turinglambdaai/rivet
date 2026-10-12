# Rivet API stability

Rivet is pre-1.0, but its public surface is deliberate. Every phase-0 export
from `rivet`, `rivet/app-info`, `rivet/backend`, `rivet/keel`,
`rivet/protocol`, `rivet/resources`, `rivet/system`, `rivet/distribution`, and
`rivet/testing` is covered by `tests/public-api.rkt`.

An API change must therefore be explicit:

1. change the implementation and documentation together;
2. update the public export snapshot intentionally;
3. record the migration in `CHANGELOG.md`; and
4. pass the full Racket suite on both the minimum supported Racket release and
   the current development baseline.

Before 1.0, incompatible changes are allowed when they remove a design trap or
create a materially clearer long-term contract. After 1.0, removing or changing
a public binding requires a major release. Additions remain minor releases, and
compatible fixes remain patch releases.

Schema type identifiers such as `String`, `Int64`, `Bool`, and `(List T)` are
syntax accepted by Rivet declaration forms. They are not exported runtime
values. Tools inspect the canonical Keel `app-schema` instead.
