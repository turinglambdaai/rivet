#lang racket/base

(require rackunit
         racket/list
         "../rivet/chart.rkt")

(define (drain-values series)
  (define-values (samples first-index) (chart-batch-decode (chart-series-drain-batch! series)))
  (values samples first-index))

(test-case "append, count, latest, window"
  (define series (make-chart-series "offset"))
  (check-equal? (chart-series-count series) 0)
  (check-equal? (chart-series-latest series) #f)
  (chart-series-append! series (list (cons 1000 10) (cons 2000 20) (cons 3000 15)))
  (check-equal? (chart-series-count series) 3)
  (check-equal? (chart-series-latest series) '(3000 . 15))
  (check-equal? (chart-series-window series) '((1000 . 10) (2000 . 20) (3000 . 15)))
  (check-equal? (chart-series-window series 1500) '((2000 . 20) (3000 . 15)))
  (check-equal? (chart-series-window series 0) '((3000 . 15))))

(test-case "timestamps must be strictly increasing"
  (define series (make-chart-series "offset"))
  (chart-series-append! series (list (cons 5000 1)))
  (check-exn exn:fail:contract?
             (lambda () (chart-series-append! series (list (cons 5000 2)))))
  (check-exn exn:fail:contract?
             (lambda () (chart-series-append! series (list (cons 4000 2)))))
  (check-equal? (chart-series-count series) 1))

(test-case "drain returns undrained samples once"
  (define series (make-chart-series "offset"))
  (chart-series-append! series (list (cons 100 1) (cons 200 2)))
  (define-values (samples-1 first-1) (drain-values series))
  (check-equal? samples-1 '((100 . 1) (200 . 2)))
  (check-equal? first-1 0)
  (define-values (samples-2 first-2) (drain-values series))
  (check-equal? samples-2 '())
  (check-equal? first-2 2)
  (chart-series-append! series (list (cons 300 3)))
  (define-values (samples-3 first-3) (drain-values series))
  (check-equal? samples-3 '((300 . 3)))
  (check-equal? first-3 2))

(test-case "ring eviction advances first-index past the host watermark"
  (define series (make-chart-series "offset" #:capacity 3))
  ;; No drain until after eviction: samples 1 and 2 are evicted undrained,
  ;; so the first batch must start at the oldest surviving absolute index
  ;; and the dropped counter reports the two undrained losses.
  (chart-series-append! series (list (cons 1 1) (cons 2 2) (cons 3 3) (cons 4 4) (cons 5 5)))
  (check-equal? (chart-series-count series) 3)
  (check-equal? (chart-series-dropped series) 2)
  (check-equal? (chart-series-appended series) 5)
  (define-values (samples first) (drain-values series))
  (check-equal? samples '((3 . 3) (4 . 4) (5 . 5)))
  (check-equal? first 2))

(test-case "draining before eviction keeps the dropped counter at zero"
  (define series (make-chart-series "offset" #:capacity 3))
  (chart-series-append! series (list (cons 1 1) (cons 2 2) (cons 3 3)))
  (define-values (drained-samples drained-first) (drain-values series))
  (check-equal? drained-samples '((1 . 1) (2 . 2) (3 . 3)))
  (check-equal? drained-first 0)
  (chart-series-append! series (list (cons 4 4) (cons 5 5)))
  (check-equal? (chart-series-dropped series) 0)
  (define-values (samples first) (drain-values series))
  (check-equal? samples '((4 . 4) (5 . 5)))
  (check-equal? first 3))

(test-case "drain after eviction with nothing pending still reports the floor"
  (define series (make-chart-series "offset" #:capacity 2))
  (chart-series-append! series (list (cons 1 1) (cons 2 2) (cons 3 3) (cons 4 4)))
  (define-values (samples first) (drain-values series))
  (check-equal? samples '((3 . 3) (4 . 4)))
  (check-equal? first 2)
  (define-values (samples-2 first-2) (drain-values series))
  (check-equal? samples-2 '())
  (check-equal? first-2 4))

(test-case "reset clears index space"
  (define series (make-chart-series "offset"))
  (chart-series-append! series (list (cons 1 1)))
  (chart-series-reset! series)
  (check-equal? (chart-series-count series) 0)
  (check-equal? (chart-series-appended series) 0)
  (chart-series-append! series (list (cons 1 9)))
  (define-values (samples first) (drain-values series))
  (check-equal? samples '((1 . 9)))
  (check-equal? first 0))

(test-case "batch golden bytes"
  ;; The cross-language contract: any decoder change that alters these bytes
  ;; must be a versioned layout change mirrored in the C++ and Swift decoders.
  (define batch (chart-batch-encode (list (cons 1 -12) (cons 2 40)) 7))
  (check-equal? (bytes-length batch) (+ 16 32))
  (check-equal? (subbytes batch 0 16)
                (bytes #x31 #x43 #x56 #x52 #x02 #x00 #x00 #x00
                       #x07 #x00 #x00 #x00 #x00 #x00 #x00 #x00))
  (check-equal? (subbytes batch 16 24)
                (integer->integer-bytes 1 8 #t #f))
  (check-equal? (subbytes batch 24 32)
                (integer->integer-bytes -12 8 #t #f))
  (check-equal? (subbytes batch 32 40)
                (integer->integer-bytes 2 8 #t #f)))

(test-case "batch roundtrip"
  (define samples
    (for/list ([n (in-range 500)])
      (cons (* n 1000) (- (random 1000000) 500000))))
  (define batch (chart-batch-encode samples 4242))
  (check-equal? (chart-batch-sample-count batch) 500)
  (check-equal? (chart-batch-first-index batch) 4242)
  (define-values (decoded first-index) (chart-batch-decode batch))
  (check-equal? decoded samples)
  (check-equal? first-index 4242))

(test-case "empty batch"
  (define batch (chart-batch-encode '() 9))
  (check-equal? (bytes-length batch) 16)
  (check-equal? (chart-batch-sample-count batch) 0)
  (define-values (samples first-index) (chart-batch-decode batch))
  (check-equal? samples '())
  (check-equal? first-index 9))

(test-case "decoder rejects malformed batches"
  (check-exn exn:fail:contract? (lambda () (chart-batch-decode #"short")))
  (check-exn exn:fail:contract?
             (lambda () (chart-batch-decode (make-bytes 32 #x00))))
  (define batch (chart-batch-encode (list (cons 1 1)) 0))
  (check-exn exn:fail:contract?
             ;; header declares more samples than the bytes carry
             (lambda ()
               (chart-batch-decode
                (bytes-append (subbytes batch 0 4)
                              (bytes #x02 #x00 #x00 #x00)
                              (subbytes batch 8))))))

(test-case "window spans monotonic gaps"
  (define series (make-chart-series "delay"))
  (chart-series-append! series
                        (list (cons 0 0) (cons 100 5) (cons 200 5) (cons 10000 6)))
  (check-equal? (chart-series-window series 500) '((10000 . 6)))
  (check-equal? (chart-series-window series 10000) '((0 . 0) (100 . 5) (200 . 5) (10000 . 6))))
