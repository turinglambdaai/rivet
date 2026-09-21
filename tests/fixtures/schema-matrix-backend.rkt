#lang racket/base

(require rivet/backend)

(provide start)

;; Keep the scaffold contract exercised by the native starter UI.
(define-event progress : Int64)
(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value Int64] : Int64)
  (add1 value))

;; Primitive type matrix.
(define-event text-event : String)
(define-event bool-event : Bool)
(define-event bytes-event : Bytes)
(define-event any-event : Any)

(define-state text-state : String "ready")
(define-state bool-state : Bool #f)
(define-state bytes-state : Bytes #"rivet")
(define-state any-state : Any "ready")

(define-rpc (roundtrip-bool [value Bool] : Bool)
  value)

(define-rpc (roundtrip-bytes [value Bytes] : Bytes)
  value)

(define-rpc (roundtrip-any [value Any] : Any)
  value)

(define-rpc (no-result [message String] : Void)
  (void))

;; Container and nested-container matrix. Optional values use Racket's void
;; sentinel on the backend and native Optional/nil/null on generated clients.
(define-event string-list-event : (List String))
(define-event optional-string-event : (Optional String))
(define-event nested-list-event : (List (Optional String)))
(define-event optional-list-event : (Optional (List Int64)))

(define-state string-list-state : (List String) '("rivet" "matrix"))
(define-state optional-string-state : (Optional String) (void))
(define-state nested-list-state : (List (Optional String))
  (list "rivet" (void) "matrix"))
(define-state optional-list-state : (Optional (List Int64)) '(1 2 3))

(define-rpc (roundtrip-string-list [value (List String)] : (List String))
  value)

(define-rpc (roundtrip-optional-string [value (Optional String)] : (Optional String))
  value)

(define-rpc (roundtrip-nested-list
             [value (List (Optional String))]
             : (List (Optional String)))
  value)

(define-rpc (roundtrip-optional-list
             [value (Optional (List Int64))]
             : (Optional (List Int64)))
  value)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
