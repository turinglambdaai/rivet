#lang racket/base

(require rackunit
         "../rivet-cli/launch-smoke.rkt")

(define racket-executable
  (or (find-executable-path "racket")
      (error 'launch-smoke-test "racket executable was not found")))

(check-true (boolean? (gui-session-available?)))

;; A healthy GUI process is expected to remain alive for the observation
;; window. The verifier owns and terminates the child after that point.
(check-not-exn
 (lambda ()
   (launch-smoke!
    racket-executable
    #:arguments '("-e" "(sleep 30)")
    #:seconds 0.2
    #:who 'test-launch-smoke!)))

(check-exn
 (lambda (error)
   (define message (exn-message error))
   (and (regexp-match? #rx"exited during launch smoke test" message)
        (regexp-match? #rx"exit-status: 23" message)
        (regexp-match? #rx"startup exploded" message)
        (regexp-match? #rx"startup output" message)))
 (lambda ()
   (launch-smoke!
    racket-executable
    #:arguments
    '("-e"
      "(begin (display \"startup output\") (eprintf \"startup exploded\") (exit 23))")
    #:seconds 2
    #:who 'test-launch-smoke!)))

;; Output is drained concurrently but retained only up to a fixed diagnostic
;; bound, so a noisy crashing application cannot deadlock or exhaust memory.
(check-exn
 (lambda (error)
   (regexp-match? #rx"output truncated at 65536 bytes" (exn-message error)))
 (lambda ()
   (launch-smoke!
    racket-executable
    #:arguments
    '("-e"
      "(begin (write-bytes (make-bytes 100000 120) (current-error-port)) (exit 2))")
    #:seconds 2
    #:who 'test-launch-smoke!)))

(check-exn
 exn:fail:contract?
 (lambda ()
   (launch-smoke! racket-executable #:seconds 0)))
