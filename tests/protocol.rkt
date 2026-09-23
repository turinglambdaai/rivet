#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/runtime-path
         racket/string
         "../rivet/protocol.rkt")

(define-runtime-path golden-path "protocol-golden.txt")

(define (hex->bytes text)
  (unless (even? (string-length text))
    (error 'hex->bytes "odd-length hex string: ~a" text))
  (apply bytes
         (for/list ([i (in-range 0 (string-length text) 2)])
           (define value (string->number (substring text i (+ i 2)) 16))
           (unless value
             (error 'hex->bytes "invalid hex string: ~a" text))
           value)))

(define golden-records
  (for/list ([line (in-list (file->lines golden-path))]
             #:unless (or (string=? "" (string-trim line))
                          (string-prefix? (string-trim line) "#")))
    (define parts (string-split line "|"))
    (unless (= (length parts) 3)
      (error 'protocol-golden "invalid fixture line: ~a" line))
    (list (first parts) (second parts) (hex->bytes (third parts)))))

(define (golden-value name)
  (cond
    [(string=? name "null") (void)]
    [(string=? name "false") #f]
    [(string=? name "true") #t]
    [(string=? name "int64-min") -9223372036854775808]
    [(string=? name "int64-neg2") -2]
    [(string=? name "int64-42") 42]
    [(string=? name "int64-max") 9223372036854775807]
    [(string=? name "string-empty") ""]
    [(string=? name "string-hello") "hello"]
    [(string=? name "string-nul") (string #\a (integer->char 0) #\b)]
    [(string=? name "string-unicode") "你好 Rivet"]
    [(string=? name "string-emoji") "🙂"]
    [(string=? name "bytes-empty") #""]
    [(string=? name "bytes-binary") #"\x00\xff\x7f"]
    [(string=? name "list-empty") '()]
    [(string=? name "list-nested") (list "nested" 7 #t)]
    [else (error 'protocol-golden "unknown value fixture: ~a" name)]))

(for ([record (in-list golden-records)])
  (define kind (first record))
  (define name (second record))
  (define encoded (third record))
  (cond
    [(string=? kind "value")
     (define expected (golden-value name))
     (check-equal? (encode-value expected) encoded name)
     (define decoded (decode-value encoded))
     (if (void? expected)
         (check-true (void? decoded) name)
         (check-equal? decoded expected name))
     ;; A valid canonical value becomes invalid at every strict byte prefix.
     ;; This covers empty input plus every possible truncation boundary for
     ;; all value shapes represented in the shared cross-language fixture.
     (for ([prefix-length (in-range (bytes-length encoded))])
       (check-exn exn:fail?
                  (lambda ()
                    (decode-value (subbytes encoded 0 prefix-length)))))
     ;; Canonical values consume their entire input. Appending even one byte
     ;; must not be silently ignored by any protocol implementation.
     (check-exn exn:fail?
                (lambda ()
                  (decode-value (bytes-append encoded #"\x00")))
                name)]
    [(string=? kind "frame")
     (unless (string=? name "request-99")
       (error 'protocol-golden "unknown frame fixture: ~a" name))
     (define decoded (read-frame (open-input-bytes encoded)))
     (check-equal? (frame-type decoded) message:request name)
     (check-equal? (frame-id decoded) 99 name)
     (check-equal? (decode-value (frame-payload decoded))
                   (list "increment" 41)
                   name)
     (define out (open-output-bytes))
     (write-frame decoded out)
     (check-equal? (get-output-bytes out) encoded name)
     ;; Empty input is the stream-level EOF sentinel, but every non-empty strict
     ;; frame prefix must be rejected as a truncated frame.
     (for ([prefix-length (in-range 1 (bytes-length encoded))])
       (check-exn exn:fail?
                  (lambda ()
                    (read-frame
                     (open-input-bytes
                      (subbytes encoded 0 prefix-length))))))]
    [(string=? kind "invalid-value")
     (check-exn exn:fail? (lambda () (decode-value encoded)) name)]
    [(string=? kind "invalid-frame")
     (check-exn exn:fail?
                (lambda () (read-frame (open-input-bytes encoded)))
                name)]
    [else
     (error 'protocol-golden "unknown fixture kind: ~a" kind)]))

;; Resource-limit regressions stay separate from the fixed byte vectors.
(define too-deep-value
  (for/fold ([value (void)])
            ([i (in-range (add1 max-value-depth))])
    (list value)))
(check-exn #rx"nesting exceeds Rivet protocol limit"
           (lambda () (encode-value too-deep-value)))

;; The root List plus max-value-nodes - 1 children exactly fills the budget.
(define max-node-value (make-list (sub1 max-value-nodes) (void)))
(define max-node-encoded (encode-value max-node-value))
(check-not-exn (lambda () (decode-value max-node-encoded)))

;; The root List itself consumes one node, so max-value-nodes elements exceed
;; the total value-node budget by one and must fail before element traversal.
(define too-many-node-value (make-list max-value-nodes (void)))
(check-exn #rx"node count exceeds Rivet protocol limit"
           (lambda () (encode-value too-many-node-value)))

;; A standalone encoded value must itself fit in one legal frame payload.
;; Reuse one 64 MiB+1 Bytes object to prove both directions reject before the
;; encoder builds another giant output buffer or the decoder starts parsing it.
(let ([oversized-value (make-bytes (add1 max-frame-payload-size) 0)])
  (check-exn #rx"encoded value exceeds Rivet payload limit"
             (lambda () (decode-value oversized-value)))
  (check-exn #rx"encoded value exceeds Rivet payload limit"
             (lambda () (encode-value oversized-value))))

(define list-prefix #"\x06\x01\x00\x00\x00")
(define too-deep-payload
  (bytes-append
   (apply bytes-append
          (make-list (add1 max-value-depth) list-prefix))
   #"\x00"))
(check-exn #rx"nesting exceeds Rivet protocol limit"
           (lambda () (decode-value too-deep-payload)))

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
