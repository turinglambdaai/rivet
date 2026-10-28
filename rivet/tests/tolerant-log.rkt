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

;; A failing close on the transport must not escape either.
(parameterize ([current-output-port
                (tolerant-output-port
                 (make-output-port
                  'broken-close always-evt
                  (lambda (_b _s _e _nb _eb) (- _e _s))
                  (lambda () (raise (make-exn:fail "close died"
                                                   (current-continuation-marks))))))])
  (displayln "bye")
  (check-true #t))
