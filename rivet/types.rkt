#lang racket/base

(provide (struct-out rivet-type)
         Void
         Bool
         Int64
         String
         Bytes
         List)

;; Public schema descriptors. `define-rpc` records the symbolic type names in
;; v0; these values give tools and future code generators one canonical place
;; to attach richer metadata without changing application source syntax.
(struct rivet-type (name) #:transparent)

(define Void   (rivet-type 'Void))
(define Bool   (rivet-type 'Bool))
(define Int64  (rivet-type 'Int64))
(define String (rivet-type 'String))
(define Bytes  (rivet-type 'Bytes))
(define List   (rivet-type 'List))
