#lang racket/base

;; Real-time chart series data plane shared by Rivet applications.
;;
;; rivet/chart keeps time-series state on the Racket side and exports it in
;; the two shapes native chart widgets consume: the recent-window pull (an
;; ordinary typed RPC result built from chart-series-window) and the
;; high-rate append push (a Bytes batch carried by an application event).
;;
;; The batch layout is the cross-language contract; the portable C++ decoder
;; lives in runtime/include/rivet/chart_batch.hpp and the Swift decoder in
;; platform/macos/Sources/RivetUI. All three must stay byte-identical and
;; are pinned by rivet/tests/chart.rkt and the native test suites.
;;
;; Samples are (timestamp-nanoseconds . value) pairs of exact integers.
;; Values stay integers on purpose: Rivet's typed surface has no Float, and
;; measurement domains are integer-native anyway (ns offsets, ps offsets,
;; ppm drift, frame counts). Display scaling belongs to the native widget.

(require racket/list)

(provide make-chart-series
         chart-series?
         chart-series-id
         chart-series-capacity
         chart-series-count
         chart-series-appended
         chart-series-dropped
         chart-series-latest
         chart-series-append!
         chart-series-reset!
         chart-series-window
         chart-series-drain-batch!
         chart-batch-encode
         chart-batch-decode
         chart-batch-sample-count
         chart-batch-first-index
         chart-batch-magic)

;; Batch layout, little-endian throughout:
;;   u32 magic  0x52564331 ("RVC1")
;;   u32 sample count
;;   i64 absolute index of the first sample in this batch
;;   count x (i64 timestamp-ns, i64 value)
;; The absolute index is the total number of samples ever appended to the
;; series at the moment the first batch sample was appended. A host that
;; kept up knows its next expected index; a mismatch means the ring dropped
;; undrained samples and the window pull is the recovery path.
(define chart-batch-magic #x52564331)
(define header-size 16)
(define sample-size 16)

(struct chart-series
        (id           ; String, matches the series id the host renders
         capacity     ; positive exact integer
         ts           ; exact-integer vector, ring buffer
         val          ; exact-integer vector, ring buffer
         head         ; ring index of the oldest live sample
         size         ; number of live samples
         appended     ; total samples ever appended (absolute index space)
         dropped      ; total live samples evicted before being drained
         drained      ; absolute index of the next undrained sample
         lock         ; semaphore 1: engine threads append, ticker drains
         )
        #:transparent
        #:mutable)

(define (make-chart-series id
                           #:capacity [capacity 16384])
  (unless (string? id)
    (raise-argument-error 'make-chart-series "string?" id))
  (unless (and (exact-positive-integer? capacity) (<= capacity (expt 2 24)))
    (raise-argument-error 'make-chart-series
                          "exact-positive-integer? <= 2^24" capacity))
  (chart-series id capacity
                (make-vector capacity 0)
                (make-vector capacity 0)
                0 0 0 0 0
                (make-semaphore 1)))

(define (chart-series-count series)
  (call-with-semaphore (chart-series-lock series)
    (lambda () (chart-series-size series))))

(define (chart-series-latest series)
  (call-with-semaphore (chart-series-lock series)
    (lambda ()
      (and (positive? (chart-series-size series))
           (let ([newest (modulo (+ (chart-series-head series)
                                    (chart-series-size series)
                                    -1)
                                 (chart-series-capacity series))])
             (cons (vector-ref (chart-series-ts series) newest)
                   (vector-ref (chart-series-val series) newest)))))))

;; Samples arrive as a list of (ts . value) pairs in append order. Timestamps
;; must be strictly increasing within the call and against the series tail;
;; a reordered feed corrupts window slicing and the host's index accounting,
;; so it is an error rather than a silent reorder.
(define (chart-series-append! series samples)
  (unless (and (list? samples)
               (andmap (lambda (sample)
                         (and (pair? sample)
                              (exact-integer? (car sample))
                              (not (negative? (car sample)))
                              (exact-integer? (cdr sample))))
                       samples))
    (raise-argument-error 'chart-series-append!
                          "(listof (cons/c exact-nonnegative-integer? exact-integer?))"
                          samples))
  (call-with-semaphore (chart-series-lock series)
    (lambda ()
      (define capacity (chart-series-capacity series))
      (define size (chart-series-size series))
      (define tail-index
        (and (positive? size)
             (modulo (+ (chart-series-head series) size -1) capacity)))
      (define tail-ts
        (and tail-index (vector-ref (chart-series-ts series) tail-index)))
      (let loop ([remaining samples]
                 [size size]
                 [tail-ts tail-ts]
                 [appended (chart-series-appended series)]
                 [dropped (chart-series-dropped series)])
        (cond
          [(null? remaining)
           (set-chart-series-size! series size)
           (set-chart-series-appended! series appended)
           (set-chart-series-dropped! series dropped)
           (void)]
          [else
           (define sample (car remaining))
           (define ts (car sample))
           (when (and tail-ts (<= ts tail-ts))
             (raise-arguments-error 'chart-series-append!
                                    "timestamps must be strictly increasing"
                                    "offending-timestamp" ts
                                    "series-tail-timestamp" tail-ts))
           (define write-index (modulo (+ (chart-series-head series) size) capacity))
           (vector-set! (chart-series-ts series) write-index ts)
           (vector-set! (chart-series-val series) write-index (cdr sample))
           (define next-size (add1 size))
           (define dropped* dropped)
           (when (> next-size capacity)
             ;; The slot being overwritten holds absolute position
             ;; `appended - capacity`; losing it only counts as a drop when
             ;; the host has not drained it yet.
             (when (>= (- appended capacity) (chart-series-drained series))
               (set! dropped* (add1 dropped)))
             (set-chart-series-head!
              series (modulo (add1 (chart-series-head series)) capacity)))
           (loop (cdr remaining) (min next-size capacity) ts (add1 appended) dropped*)])))))

(define (chart-series-reset! series)
  (call-with-semaphore (chart-series-lock series)
    (lambda ()
      (set-chart-series-head! series 0)
      (set-chart-series-size! series 0)
      (set-chart-series-appended! series 0)
      (set-chart-series-dropped! series 0)
      (set-chart-series-drained! series 0)
      (void))))

;; Newest-last list of live samples no older than the newest timestamp minus
;; span-ns; #f keeps the whole live ring. This is the initial-paint and
;; gap-recovery pull behind an ordinary typed RPC.
(define (chart-series-window series [span-ns #f])
  (call-with-semaphore (chart-series-lock series)
    (lambda ()
      (define size (chart-series-size series))
      (define capacity (chart-series-capacity series))
      (cond
        [(zero? size) '()]
        [else
         (define newest (modulo (+ (chart-series-head series) size -1) capacity))
         (define newest-ts (vector-ref (chart-series-ts series) newest))
         (define cutoff
           (and span-ns (max 0 (- newest-ts span-ns))))
         (define collected
           (for/list ([offset (in-range (sub1 size) -1 -1)]
                      #:break (and cutoff
                                   (< (vector-ref (chart-series-ts series)
                                                  (modulo (+ (chart-series-head series) offset) capacity))
                                      cutoff)))
             (define index (modulo (+ (chart-series-head series) offset) capacity))
             (cons (vector-ref (chart-series-ts series) index)
                   (vector-ref (chart-series-val series) index))))
         (reverse collected)]))))

;; One batch with every sample appended since the previous drain. The first
;; index in the header is the absolute index of the first returned sample;
;; hosts compare it against their applied watermark to detect ring eviction.
(define (chart-series-drain-batch! series)
  (call-with-semaphore (chart-series-lock series)
    (lambda ()
      (define size (chart-series-size series))
      (define capacity (chart-series-capacity series))
      (define appended (chart-series-appended series))
      (define drained (chart-series-drained series))
      (define oldest-live (- appended size))
      (define first-index (max drained oldest-live))
      (define samples
        (for/list ([position (in-range first-index appended)])
          (define ring-index
            (modulo (+ (chart-series-head series) (- position oldest-live)) capacity))
          (cons (vector-ref (chart-series-ts series) ring-index)
                (vector-ref (chart-series-val series) ring-index))))
      (set-chart-series-drained! series appended)
      (chart-batch-encode samples first-index))))

;; -- Batch codec ------------------------------------------------------

(define (write-u32-le! bytes offset value)
  (bytes-set! bytes offset (bitwise-bit-field value 0 8))
  (bytes-set! bytes (add1 offset) (bitwise-bit-field value 8 16))
  (bytes-set! bytes (+ offset 2) (bitwise-bit-field value 16 24))
  (bytes-set! bytes (+ offset 3) (bitwise-bit-field value 24 32)))

(define (write-i64-le! bytes offset value)
  (integer->integer-bytes value 8 #t #f bytes offset))

(define (read-u32-le bytes offset)
  (+ (bytes-ref bytes offset)
     (* (bytes-ref bytes (add1 offset)) 256)
     (* (bytes-ref bytes (+ offset 2)) 65536)
     (* (bytes-ref bytes (+ offset 3)) 16777216)))

(define (check-sample sample who)
  (unless (and (pair? sample)
               (exact-nonnegative-integer? (car sample))
               (exact-integer? (cdr sample)))
    (raise-argument-error who
                          "(cons/c exact-nonnegative-integer? exact-integer?)"
                          sample)))

(define (chart-batch-encode samples [first-index 0])
  (unless (and (list? samples) (andmap (lambda (s) (check-sample s 'chart-batch-encode)) samples))
    (raise-argument-error 'chart-batch-encode
                          "(listof (cons/c exact-nonnegative-integer? exact-integer?))"
                          samples))
  (unless (exact-nonnegative-integer? first-index)
    (raise-argument-error 'chart-batch-encode
                          "exact-nonnegative-integer?" first-index))
  (define count (length samples))
  (define batch (make-bytes (+ header-size (* count sample-size))))
  (write-u32-le! batch 0 chart-batch-magic)
  (write-u32-le! batch 4 count)
  (write-i64-le! batch 8 first-index)
  (for ([sample (in-list samples)]
        [position (in-naturals)])
    (define base (+ header-size (* position sample-size)))
    (write-i64-le! batch base (car sample))
    (write-i64-le! batch (+ base 8) (cdr sample)))
  batch)

(define (chart-batch-decode batch)
  (unless (bytes? batch)
    (raise-argument-error 'chart-batch-decode "bytes?" batch))
  (unless (>= (bytes-length batch) header-size)
    (raise-arguments-error 'chart-batch-decode
                           "batch shorter than its header"
                           "batch-length" (bytes-length batch)))
  (define magic (read-u32-le batch 0))
  (unless (= magic chart-batch-magic)
    (raise-arguments-error 'chart-batch-decode
                           "batch magic mismatch"
                           "expected" chart-batch-magic
                           "actual" magic))
  (define count (read-u32-le batch 4))
  (define expected-size (+ header-size (* count sample-size)))
  (unless (= (bytes-length batch) expected-size)
    (raise-arguments-error 'chart-batch-decode
                           "batch length does not match its declared count"
                           "declared-count" count
                           "expected-length" expected-size
                           "actual-length" (bytes-length batch)))
  (define first-index (integer-bytes->integer batch #f #f 8 16))
  (define samples
    (for/list ([position (in-range count)])
      (define base (+ header-size (* position sample-size)))
      (cons (integer-bytes->integer batch #t #f base (+ base 8))
            (integer-bytes->integer batch #t #f (+ base 8) (+ base 16)))))
  (values samples first-index))

(define (chart-batch-sample-count batch)
  (unless (and (bytes? batch) (>= (bytes-length batch) header-size))
    (raise-argument-error 'chart-batch-sample-count "valid chart batch" batch))
  (read-u32-le batch 4))

(define (chart-batch-first-index batch)
  (unless (and (bytes? batch) (>= (bytes-length batch) header-size))
    (raise-argument-error 'chart-batch-first-index "valid chart batch" batch))
  (integer-bytes->integer batch #f #f 8 16))
