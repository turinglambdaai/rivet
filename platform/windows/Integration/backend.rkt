#lang racket/base

(require rivet/backend)

(provide start)

(define-state counter : Int64 10)

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define-rpc (wait-for-cancel : Int64)
  (sleep 3)
  1)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
