#lang racket/base

(require rackunit
         "../rivet/protocol.rkt")

(define max-u64 (sub1 (expt 2 64)))

;; Both unsigned-64 boundary ids are legal and survive a complete frame
;; round-trip. C++ and Swift model this field as UInt64, so Racket must expose
;; the same wire domain.
(for ([id (in-list (list 0 max-u64))])
  (define out (open-output-bytes))
  (write-frame (frame message:request id #"payload") out)
  (define decoded (read-frame (open-input-bytes (get-output-bytes out))))
  (check-equal? (frame-id decoded) id)
  (check-equal? (frame-payload decoded) #"payload"))

;; Invalid local frame ids must fail before write-frame emits even the RVT1
;; magic. A partial header would desynchronize the transport and make every
;; subsequent otherwise-valid frame unreadable by the native peer.
(for ([bad-id (in-list (list -1
                             (expt 2 64)
                             1.5
                             "not-an-id"))])
  (define out (open-output-bytes))
  (check-exn
   exn:fail?
   (lambda ()
     (write-frame (frame message:request bad-id #"") out)))
  (check-equal? (get-output-bytes out) #""))
