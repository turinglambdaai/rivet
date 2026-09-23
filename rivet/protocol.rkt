#lang racket/base

(require racket/port)

(provide protocol-version
         max-frame-payload-size
         max-value-depth
         max-value-nodes
         message:hello
         message:request
         message:response
         message:error
         message:event
         message:cancel
         message:shutdown
         (struct-out frame)
         write-frame
         read-frame
         encode-value
         decode-value)

;; Rivet wire protocol v1.
;;
;; Frame layout (little endian):
;;   4 bytes  magic: "RVT1"
;;   1 byte   protocol version
;;   1 byte   message type
;;   8 bytes  request/event id
;;   4 bytes  payload length
;;   N bytes  payload
;;
;; Payloads use a deliberately small tagged value codec. The framing and
;; value codec are independent so records/enums can be layered on later
;; without changing transport semantics.

(define protocol-version 1)
(define max-frame-payload-size (* 64 1024 1024))
(define max-value-depth 64)
;; A large flat List can fit in a 64 MiB frame while expanding to far more
;; memory as language-level objects. Count every decoded/encoded value node,
;; including the root, so malformed or accidental values cannot amplify
;; memory without bound. Bulk payloads should use Bytes instead of huge Lists.
(define max-value-nodes (expt 2 18))
(define max-frame-id (sub1 (expt 2 64)))
(define magic #"RVT1")

(define message:hello    1)
(define message:request  2)
(define message:response 3)
(define message:error    4)
(define message:event    5)
(define message:cancel   6)
(define message:shutdown 7)

(define (valid-message-type? type)
  (and (exact-integer? type)
       (<= message:hello type message:shutdown)))

(define (valid-frame-id? id)
  (and (exact-integer? id)
       (<= 0 id max-frame-id)))

(struct frame (type id payload) #:transparent)

(define (write-u32 n out)
  (write-bytes (integer->integer-bytes n 4 #f #f) out))

(define (write-u64 n out)
  (write-bytes (integer->integer-bytes n 8 #f #f) out))

(define (read-exactly in n)
  (define bs (read-bytes n in))
  (cond
    [(eof-object? bs) eof]
    [(= (bytes-length bs) n) bs]
    [else
     (define out (open-output-bytes))
     (write-bytes bs out)
     (let loop ([remaining (- n (bytes-length bs))])
       (cond
         [(zero? remaining) (get-output-bytes out)]
         [else
          (define chunk (read-bytes remaining in))
          (when (eof-object? chunk)
            (error 'read-frame "unexpected EOF"))
          (write-bytes chunk out)
          (loop (- remaining (bytes-length chunk)))]))]))

(define (bytes->u32 bs)
  (integer-bytes->integer bs #f #f))

(define (bytes->u64 bs)
  (integer-bytes->integer bs #f #f))

(define (write-frame f [out (current-output-port)])
  (unless (frame? f)
    (raise-argument-error 'write-frame "frame?" f))
  (unless (valid-message-type? (frame-type f))
    (raise-arguments-error 'write-frame
                           "unknown Rivet message type"
                           "type" (frame-type f)))
  ;; C++ and Swift expose the wire id as UInt64. Validate the Racket value
  ;; before writing any header bytes so a local argument error cannot leave a
  ;; partial frame on the transport and desynchronize every subsequent frame.
  (unless (valid-frame-id? (frame-id f))
    (raise-arguments-error 'write-frame
                           "frame id is outside the unsigned 64-bit range"
                           "id" (frame-id f)
                           "minimum" 0
                           "maximum" max-frame-id))
  (define payload (frame-payload f))
  (unless (bytes? payload)
    (raise-argument-error 'write-frame "bytes? payload" payload))
  (when (> (bytes-length payload) max-frame-payload-size)
    (raise-arguments-error 'write-frame
                           "payload exceeds Rivet protocol limit"
                           "length" (bytes-length payload)
                           "maximum" max-frame-payload-size))
  (write-bytes magic out)
  (write-byte protocol-version out)
  (write-byte (frame-type f) out)
  (write-u64 (frame-id f) out)
  (write-u32 (bytes-length payload) out)
  (write-bytes payload out)
  (flush-output out))

(define (read-frame [in (current-input-port)])
  (define got-magic (read-exactly in 4))
  (cond
    [(eof-object? got-magic) eof]
    [else
     (unless (bytes=? got-magic magic)
       (error 'read-frame "invalid Rivet frame magic"))
     (define version (read-byte in))
     (when (eof-object? version)
       (error 'read-frame "unexpected EOF after frame magic"))
     (unless (= version protocol-version)
       (error 'read-frame
              "unsupported protocol version ~a (expected ~a)"
              version protocol-version))
     (define type (read-byte in))
     (when (eof-object? type)
       (error 'read-frame "unexpected EOF while reading message type"))
     (unless (valid-message-type? type)
       (error 'read-frame "unknown Rivet message type: ~a" type))
     (define id-bytes (read-exactly in 8))
     (define len-bytes (read-exactly in 4))
     (when (or (eof-object? id-bytes) (eof-object? len-bytes))
       (error 'read-frame "unexpected EOF while reading frame header"))
     (define len (bytes->u32 len-bytes))
     (when (> len max-frame-payload-size)
       (raise-arguments-error 'read-frame
                              "payload exceeds Rivet protocol limit"
                              "length" len
                              "maximum" max-frame-payload-size))
     (define payload (read-exactly in len))
     (when (eof-object? payload)
       (error 'read-frame "unexpected EOF while reading payload"))
     (frame type (bytes->u64 id-bytes) payload)]))

;; Value codec tags.
(define tag:null   #x00)
(define tag:false  #x01)
(define tag:true   #x02)
(define tag:int64  #x03)
(define tag:string #x04)
(define tag:bytes  #x05)
(define tag:list   #x06)

;; Racket lists do not carry their length. A plain `list?` followed by `length`
;; traverses the entire value twice before the encoder can apply its node
;; budget. Stop as soon as the remaining value-node budget would be exceeded.
;; Return #f for an improper list and 'too-many when the proper-list prefix has
;; already exhausted the budget.
(define (bounded-list-length value limit)
  (let loop ([rest value] [count 0])
    (cond
      [(null? rest) count]
      [(not (pair? rest)) #f]
      [(>= count limit) 'too-many]
      [else (loop (cdr rest) (add1 count))])))

(define (encode-value v)
  (define out (open-output-bytes))
  (define remaining-nodes max-value-nodes)
  (define remaining-bytes max-frame-payload-size)
  (define (consume-node!)
    (when (zero? remaining-nodes)
      (raise-arguments-error 'encode-value
                             "value node count exceeds Rivet protocol limit"
                             "maximum nodes" max-value-nodes))
    (set! remaining-nodes (sub1 remaining-nodes)))
  (define (consume-bytes! count)
    (when (> count remaining-bytes)
      (raise-arguments-error 'encode-value
                             "encoded value exceeds Rivet payload limit"
                             "maximum bytes" max-frame-payload-size))
    (set! remaining-bytes (- remaining-bytes count)))
  (define (emit value depth)
    (consume-node!)
    (cond
      [(void? value)
       (consume-bytes! 1)
       (write-byte tag:null out)]
      [(eq? value #f)
       (consume-bytes! 1)
       (write-byte tag:false out)]
      [(eq? value #t)
       (consume-bytes! 1)
       (write-byte tag:true out)]
      [(and (exact-integer? value)
            (<= (- (expt 2 63)) value (sub1 (expt 2 63))))
       (consume-bytes! 9)
       (write-byte tag:int64 out)
       (write-bytes (integer->integer-bytes value 8 #t #f) out)]
      [(string? value)
       ;; Measure UTF-8 bytes without first allocating the encoded byte string.
       ;; Oversized strings therefore fail before materializing a second large
       ;; representation solely to discover that it cannot fit in one frame.
       (define len (string-utf-8-length value))
       (consume-bytes! (+ 5 len))
       (define bs (string->bytes/utf-8 value))
       (write-byte tag:string out)
       (write-u32 len out)
       (write-bytes bs out)]
      [(bytes? value)
       (define len (bytes-length value))
       (consume-bytes! (+ 5 len))
       (write-byte tag:bytes out)
       (write-u32 len out)
       (write-bytes value out)]
      [(or (null? value) (pair? value))
       (when (>= depth max-value-depth)
         (raise-arguments-error 'encode-value
                                "value nesting exceeds Rivet protocol limit"
                                "maximum depth" max-value-depth))
       (define count (bounded-list-length value remaining-nodes))
       (cond
         [(eq? count 'too-many)
          (raise-arguments-error 'encode-value
                                 "value node count exceeds Rivet protocol limit"
                                 "maximum nodes" max-value-nodes)]
         [(not count)
          (error 'encode-value "value is not a proper List")]
         [else
          (consume-bytes! 5)
          (write-byte tag:list out)
          (write-u32 count out)
          (for ([item (in-list value)])
            (emit item (add1 depth)))])]
      [else
       (raise-arguments-error 'encode-value
                              "value is not supported by protocol v1"
                              "value" value)]))
  (emit v 0)
  (get-output-bytes out))

(define (decode-value bs)
  (unless (bytes? bs)
    (raise-argument-error 'decode-value "bytes?" bs))
  (when (> (bytes-length bs) max-frame-payload-size)
    (raise-arguments-error 'decode-value
                           "encoded value exceeds Rivet payload limit"
                           "length" (bytes-length bs)
                           "maximum" max-frame-payload-size))
  (define in (open-input-bytes bs))
  (define remaining-nodes max-value-nodes)
  (define (consume-node!)
    (when (zero? remaining-nodes)
      (error 'decode-value
             "value node count exceeds Rivet protocol limit (~a)"
             max-value-nodes))
    (set! remaining-nodes (sub1 remaining-nodes)))
  (define (remaining-input-bytes)
    (- (bytes-length bs) (file-position in)))
  (define (read-sized-bytes! len kind)
    ;; Validate against the actual bounded input before asking the port to read
    ;; `len`, so a forged u32 such as #xffffffff cannot request a huge buffer.
    (when (> len (remaining-input-bytes))
      (error 'decode-value "unexpected EOF in ~a" kind))
    (define b (read-exactly in len))
    (when (eof-object? b) (error 'decode-value "unexpected EOF in ~a" kind))
    b)
  (define (read-u32*)
    (define b (read-exactly in 4))
    (when (eof-object? b) (error 'decode-value "unexpected EOF"))
    (bytes->u32 b))
  (define (read-one depth)
    (consume-node!)
    (define tag (read-byte in))
    (when (eof-object? tag)
      (error 'decode-value "unexpected EOF"))
    (case tag
      [(#x00) (void)]
      [(#x01) #f]
      [(#x02) #t]
      [(#x03)
       (define b (read-exactly in 8))
       (when (eof-object? b) (error 'decode-value "unexpected EOF in int64"))
       (integer-bytes->integer b #t #f)]
      [(#x04)
       (define len (read-u32*))
       (bytes->string/utf-8 (read-sized-bytes! len "string"))]
      [(#x05)
       (define len (read-u32*))
       (read-sized-bytes! len "bytes")]
      [(#x06)
       (when (>= depth max-value-depth)
         (error 'decode-value
                "value nesting exceeds Rivet protocol limit (~a)"
                max-value-depth))
       (define count (read-u32*))
       ;; Each declared element requires at least one node. Check this before
       ;; allocating a result List so a tiny payload cannot request a huge
       ;; language-level container.
       (when (> count remaining-nodes)
         (error 'decode-value
                "value node count exceeds Rivet protocol limit (~a)"
                max-value-nodes))
       (define remaining (remaining-input-bytes))
       ;; Every encoded list element consumes at least one tag byte.
       (when (> count remaining)
         (error 'decode-value "impossible list length: ~a" count))
       (for/list ([i (in-range count)]) (read-one (add1 depth)))]
      [else
       (error 'decode-value "unknown value tag: ~a" tag)]))
  (define value (read-one 0))
  (unless (eof-object? (peek-byte in))
    (error 'decode-value "trailing bytes after value"))
  value)
