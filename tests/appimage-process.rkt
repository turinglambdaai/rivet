#lang racket/base

(require rackunit
         racket/string
         racket/system
         (submod "../rivet-cli/appimage.rkt" test-support))

(define racket-executable (find-executable-path "racket"))

(check-equal?
 (string-trim (run/capture 'appimage-process-test racket-executable '("-e" "(display \"captured\")")))
 "captured")

(check-exn #rx"external command failed.*exit-code"
           (lambda ()
             (run/capture 'appimage-process-test
                          racket-executable
                          '("-e" "(begin (eprintf \"diagnostic\") (exit 7))"))))
