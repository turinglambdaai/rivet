#lang racket/base

(require rackunit
         "../rivet/protocol.rkt")

(define values
  (list (void)
        #f
        #t
        -42
        0
        42
        "hello"
        #"bytes"
        (list "nested" 7 #t)))

(for ([v (in-list values)])
  (define decoded (decode-value (encode-value v)))
  (cond
    [(void? v) (check-true (void? decoded))]
    [else (check-equal? decoded v)]))

(define payload (encode-value (list "increment" 41)))
(define original (frame message:request 99 payload))
(define out (open-output-bytes))
(write-frame original out)
(define decoded-frame (read-frame (open-input-bytes (get-output-bytes out))))

(check-equal? (frame-type decoded-frame) message:request)
(check-equal? (frame-id decoded-frame) 99)
(check-equal? (decode-value (frame-payload decoded-frame))
              (list "increment" 41))

(check-exn exn:fail?
           (lambda () (decode-value #"\xff")))


(check-exn exn:fail?
           (lambda ()
             (decode-value #"\x06\xff\xff\xff\xff")))

(define oversized-header-out (open-output-bytes))
(write-bytes #"RVT1" oversized-header-out)
(write-byte protocol-version oversized-header-out)
(write-byte message:request oversized-header-out)
(write-bytes (integer->integer-bytes 0 8 #f #f) oversized-header-out)
(write-bytes
 (integer->integer-bytes (add1 max-frame-payload-size) 4 #f #f)
 oversized-header-out)
(check-exn exn:fail?
           (lambda ()
             (read-frame
              (open-input-bytes
               (get-output-bytes oversized-header-out)))))
