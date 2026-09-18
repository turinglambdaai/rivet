#lang racket/base

(require racket/port)

(provide protocol-version
         max-frame-payload-size
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
(define magic #"RVT1")

(define message:hello    1)
(define message:request  2)
(define message:response 3)
(define message:error    4)
(define message:event    5)
(define message:cancel   6)
(define message:shutdown 7)

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

(define (encode-value v)
  (define out (open-output-bytes))
  (define (emit value)
    (cond
      [(void? value) (write-byte tag:null out)]
      [(eq? value #f) (write-byte tag:false out)]
      [(eq? value #t) (write-byte tag:true out)]
      [(and (exact-integer? value)
            (<= (- (expt 2 63)) value (sub1 (expt 2 63))))
       (write-byte tag:int64 out)
       (write-bytes (integer->integer-bytes value 8 #t #f) out)]
      [(string? value)
       (define bs (string->bytes/utf-8 value))
       (write-byte tag:string out)
       (write-u32 (bytes-length bs) out)
       (write-bytes bs out)]
      [(bytes? value)
       (write-byte tag:bytes out)
       (write-u32 (bytes-length value) out)
       (write-bytes value out)]
      [(list? value)
       (write-byte tag:list out)
       (write-u32 (length value) out)
       (for ([item (in-list value)]) (emit item))]
      [else
       (raise-arguments-error 'encode-value
                              "value is not supported by protocol v1"
                              "value" value)]))
  (emit v)
  (get-output-bytes out))

(define (decode-value bs)
  (unless (bytes? bs)
    (raise-argument-error 'decode-value "bytes?" bs))
  (define in (open-input-bytes bs))
  (define (read-u32*)
    (define b (read-exactly in 4))
    (when (eof-object? b) (error 'decode-value "unexpected EOF"))
    (bytes->u32 b))
  (define (read-one)
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
       (define b (read-exactly in len))
       (when (eof-object? b) (error 'decode-value "unexpected EOF in string"))
       (bytes->string/utf-8 b)]
      [(#x05)
       (define len (read-u32*))
       (define b (read-exactly in len))
       (when (eof-object? b) (error 'decode-value "unexpected EOF in bytes"))
       b]
      [(#x06)
       (define count (read-u32*))
       (define position (file-position in))
       (define remaining (- (bytes-length bs) position))
       ;; Every encoded list element consumes at least one tag byte.
       (when (> count remaining)
         (error 'decode-value "impossible list length: ~a" count))
       (for/list ([i (in-range count)]) (read-one))]
      [else
       (error 'decode-value "unknown value tag: ~a" tag)]))
  (define value (read-one))
  (unless (eof-object? (peek-byte in))
    (error 'decode-value "trailing bytes after value"))
  value)
