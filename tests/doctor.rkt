#lang racket/base

(require json
         racket/port
         rackunit
         "../rivet-cli/doctor.rkt")

(define report (doctor-report))

(check-true (hash? report))
(for ([key (in-list '(os
                      architecture
                      supported
                      usable
                      ui
                      racket-executable
                      raco
                      racket-version
                      runtime
                      runtime-error
                      tools))])
  (check-true (hash-has-key? report key)))

(check-true (string? (hash-ref report 'os)))
(check-true (string? (hash-ref report 'architecture)))
(check-true (boolean? (hash-ref report 'supported)))
(check-true (boolean? (hash-ref report 'usable)))
(check-true (string? (hash-ref report 'racket-version)))
(check-true (hash? (hash-ref report 'tools)))

;; `doctor --json` is intended for CI and agents. Keep the report inside the
;; Racket JSON data model and verify it survives a complete encode/decode pass.
(define encoded
  (let ([out (open-output-string)])
    (write-json report out)
    (get-output-string out)))
(check-true (positive? (string-length encoded)))

(define decoded
  (call-with-input-string encoded read-json))
(check-equal? (hash-ref decoded 'os) (hash-ref report 'os))
(check-equal? (hash-ref decoded 'architecture) (hash-ref report 'architecture))
(check-equal? (hash-ref decoded 'supported) (hash-ref report 'supported))
(check-equal? (hash-ref decoded 'usable) (hash-ref report 'usable))
(check-equal? (hash-ref decoded 'racket-version) (hash-ref report 'racket-version))
