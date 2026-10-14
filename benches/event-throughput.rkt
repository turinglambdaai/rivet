#lang racket/base

;; Event-channel throughput bench for the chart data plane.
;;
;; Drives the real serve path over pipes like rivet/tests/backend.rkt: one RPC
;; bursts N chart-batch events, the client reader drains every frame and
;; discards it, and the wall time covers Racket-side encode + frame +
;; pipe write on the server and read-frame on the client. Run with:
;;
;;   racket benches/event-throughput.rkt

(require "../rivet/backend.rkt"
         "../rivet/chart.rkt"
         "../rivet/protocol.rkt")

(define-record ChartBenchEnvelope ([batch : Bytes]))

(define-event chart-bench : ChartBenchEnvelope)

(define-rpc (bench-burst [count : Int64] [size : Int64] : Int64)
  (define payload
    (chart-batch-encode
     (for/list ([i (in-range size)])
       (cons (* i 1000000) (- (modulo i 500) 250)))
     0))
  (for ([i (in-range count)])
    (chart-bench (ChartBenchEnvelope payload)))
  count)

(define-values (server-in client-out) (make-pipe 64))
(define-values (client-in server-out) (make-pipe 64))

(define server-thread
  (thread (lambda () (serve server-in server-out))))

(define hello (read-frame client-in))
(unless (= (frame-type hello) message:hello)
  (error 'bench "expected hello"))

(define next-id 1)

(define (bench label count size)
  (define id next-id)
  (set! next-id (add1 next-id))
  (write-frame
   (frame message:request id
          (encode-value (cons "bench-burst" (list count size))))
   client-out)
  (define start (current-inexact-monotonic-milliseconds))
  (let loop ()
    (define frame (read-frame client-in))
    (case (frame-type frame)
      [(5) (loop)]
      [(3)
       (define elapsed (- (current-inexact-monotonic-milliseconds) start))
       (define per-second (/ count (/ elapsed 1000)))
       (printf "~a: ~a events in ~a ms => ~a events/s\n"
               label count (exact->inexact elapsed)
               (real->decimal-string per-second 0))]
      [else (error 'bench "unexpected frame type ~a" (frame-type frame))])))

;; Chart-batch shapes: a 2-sample tick batch (48 B), a 30 Hz drain of a
;; 128 Hz stream (16 samples, 272 B), and a full 16k-sample window (256 KiB).
(bench "2-sample tick batch (48 B)" 20000 2)
(bench "16-sample drain batch (272 B)" 10000 16)
(bench "16384-sample window batch (256 KiB)" 50 16384)

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
