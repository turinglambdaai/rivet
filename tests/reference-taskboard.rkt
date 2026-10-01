#lang racket/base

;; Keep the canonical example inside the repository-wide `raco test tests/`
;; contract while leaving its executable behavior test beside the example.
(dynamic-require "../examples/taskboard/tests/backend.rkt" #f)
