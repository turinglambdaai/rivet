#lang racket/base

(require rackunit
         racket/port
         racket/string
         "../../rivet-cli/tolerant-log.rkt")

;; Data passes through to a healthy underlying port, intact.
(check-equal?
 (let ([sink (open-output-string)])
   (parameterize ([current-output-port (tolerant-output-port sink)]
                  [current-error-port (tolerant-output-port sink)])
     (printf "rivet: hello ~a\n" 42)
     (flush-output))
   (get-output-string sink))
 "rivet: hello 42\n")

;; A dead transport degrades to dropped output instead of raising, for
;; as many writes as it takes (issue #339).
(define (broken-port name)
  (make-output-port
   name always-evt
   (lambda (_bytes _start _end _non-block? _enable-break?)
     (raise (make-exn:fail "log transport died" (current-continuation-marks))))
   void))

(parameterize ([current-output-port (tolerant-output-port (broken-port 'out))]
               [current-error-port (tolerant-output-port (broken-port 'err))])
  ;; Thousands of writes: a long tool run must survive the transport
  ;; dying on the first one and stay alive after it.
  (for ([i (in-range 5000)])
    (printf "rivet: progress ~a\n" i)
    (eprintf "rivet: diagnostic ~a\n" i)
    (flush-output))
  (check-true #t))

;; The wrapper does not own the ambient output port. Closing it must not
;; close stdout/stderr for the caller or trigger a broken base close handler.
(define borrowed-sink (open-output-string))
(define proxy (tolerant-output-port borrowed-sink))
(display "before" proxy)
(close-output-port proxy)
(check-false (port-closed? borrowed-sink))
(display "after" borrowed-sink)
(check-equal? (get-output-string borrowed-sink) "beforeafter")

(define close-count (box 0))
(define borrowed-with-close-hook
  (make-output-port
   'borrowed always-evt
   (lambda (_b _s _e _nb _eb) (- _e _s))
   (lambda () (set-box! close-count (add1 (unbox close-count)))
             (error 'borrowed "caller owns close"))))
(close-output-port (tolerant-output-port borrowed-with-close-hook))
(check-equal? (unbox close-count) 0)
(check-false (port-closed? borrowed-with-close-hook))
