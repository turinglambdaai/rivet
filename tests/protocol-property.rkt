#lang racket/base

(require rackunit
         "../rivet/protocol.rkt")

;; Keep this deterministic corpus in lock-step with the C++ and Swift property
;; tests. Besides round-tripping each generated value, all three implementations
;; assert the same final PRNG state and FNV-1a fingerprint over encoded bytes.
(define corpus-count 512)
(define corpus-seed #x72697665742d7631)
(define corpus-final-state #xa6bf907b781d9548)
(define corpus-fingerprint #x2c89b9f6a1b6232c)

(define uint64-mask (sub1 (expt 2 64)))
(define uint64-modulus (expt 2 64))
(define int64-sign-bit (expt 2 63))
(define lcg-multiplier 6364136223846793005)
(define lcg-increment 1442695040888963407)
(define fnv-offset 14695981039346656037)
(define fnv-prime 1099511628211)

(define rng-state corpus-seed)

(define (next-u64!)
  (set! rng-state
        (bitwise-and uint64-mask
                     (+ (* rng-state lcg-multiplier) lcg-increment)))
  rng-state)

(define string-tokens
  (vector "a" (string (integer->char 0)) "你" "🙂" "Rivet"))

(define (random-value depth)
  (define variant-count (if (>= depth 4) 5 6))
  (case (modulo (next-u64!) variant-count)
    [(0) (void)]
    [(1) (not (zero? (bitwise-and (next-u64!) 1)))]
    [(2)
     (define raw (next-u64!))
     (if (>= raw int64-sign-bit)
         (- raw uint64-modulus)
         raw)]
    [(3)
     (define count (modulo (next-u64!) 8))
     (apply string-append
            (for/list ([i (in-range count)])
              (vector-ref string-tokens
                          (modulo (next-u64!)
                                  (vector-length string-tokens)))))]
    [(4)
     (define count (modulo (next-u64!) 24))
     (list->bytes
      (for/list ([i (in-range count)])
        (bitwise-and (next-u64!) #xff)))]
    [(5)
     (define count (modulo (next-u64!) 4))
     (for/list ([i (in-range count)])
       (random-value (add1 depth)))]))

(define (fnv-byte hash byte)
  (bitwise-and uint64-mask
               (* (bitwise-xor hash byte) fnv-prime)))

(define (fingerprint-value hash encoded)
  ;; Prefix each encoded value with its little-endian uint64 byte length so the
  ;; aggregate fingerprint cannot confuse different concatenation boundaries.
  (define with-length
    (for/fold ([current hash])
              ([i (in-range 8)])
      (fnv-byte current
                (bitwise-and
                 (arithmetic-shift (bytes-length encoded) (* -8 i))
                 #xff))))
  (for/fold ([current with-length])
            ([byte (in-bytes encoded)])
    (fnv-byte current byte)))

(define fingerprint fnv-offset)

(for ([case-index (in-range corpus-count)])
  (define value (random-value 0))
  (define encoded (encode-value value))
  (define decoded (decode-value encoded))

  ;; Canonical encode/decode must be stable even for nested values containing
  ;; Void/null, where comparing host-language values directly is less useful.
  (check-equal? (encode-value decoded) encoded
                (format "corpus case ~a round-trip" case-index))

  ;; Every strict prefix of a canonical standalone value is truncated.
  (for ([prefix-length (in-range (bytes-length encoded))])
    (check-exn exn:fail?
               (lambda ()
                 (decode-value (subbytes encoded 0 prefix-length)))
               (format "corpus case ~a prefix ~a"
                       case-index
                       prefix-length)))

  ;; Canonical standalone values must also reject trailing bytes.
  (check-exn exn:fail?
             (lambda () (decode-value (bytes-append encoded #"\x00")))
             (format "corpus case ~a trailing byte" case-index))

  (set! fingerprint (fingerprint-value fingerprint encoded)))

(check-equal? rng-state corpus-final-state "deterministic corpus PRNG state")
(check-equal? fingerprint corpus-fingerprint "deterministic corpus fingerprint")

;; Exhaust the complete one-byte discriminant domains. This catches future
;; accidental widening independently of the fixed invalid golden vectors.
(for ([raw-tag (in-range 7 256)])
  (check-exn exn:fail?
             (lambda () (decode-value (bytes raw-tag)))
             (format "unknown value tag 0x~x" raw-tag)))

(define (minimal-frame-bytes version type)
  (bytes-append #"RVT1"
                (bytes version type)
                (make-bytes 12 0)))

(for ([raw-type (in-range 256)])
  (define encoded (minimal-frame-bytes protocol-version raw-type))
  (if (<= message:hello raw-type message:shutdown)
      (let ([decoded (read-frame (open-input-bytes encoded))])
        (check-equal? (frame-type decoded)
                      raw-type
                      (format "known message type ~a" raw-type)))
      (check-exn exn:fail?
                 (lambda () (read-frame (open-input-bytes encoded)))
                 (format "unknown message type ~a" raw-type))))

(for ([raw-version (in-range 256)])
  (define encoded (minimal-frame-bytes raw-version message:request))
  (if (= raw-version protocol-version)
      (check-not-exn
       (lambda () (read-frame (open-input-bytes encoded)))
       "protocol version 1")
      (check-exn exn:fail?
                 (lambda () (read-frame (open-input-bytes encoded)))
                 (format "unsupported protocol version ~a" raw-version))))
