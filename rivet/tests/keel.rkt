#lang racket/base

(require rackunit
         racket/runtime-path
         rivet
         (prefix-in keel: keel)
         (prefix-in codegen: "../../rivet-cli/codegen/model.rkt"))

(define-runtime-path schema-matrix-backend
  "fixtures/schema-matrix-backend.rkt")

(define-enum AccessLevel (viewer editor owner))

(define-record
 Profile
 ([id : Int64] [display-name : String] [access : AccessLevel] [nickname : (Optional String)]))

(define-event profile-updated : Profile)
(define-state active-profile : (Optional Profile) (void))
(define-state signed-in? : Bool #f)

(define-rpc (fetch-profile [id : Int64] : (Optional Profile)) (void))

(define-rpc (profile-exists? [id : Int64] : Bool) #f)

(define schema (current-backend-app-schema #:id "rivet.keel-test" #:revision 7))

(check-true (keel:app-schema? schema))
(check-equal? (keel:app-schema-id schema) "rivet.keel-test")
(check-equal? (keel:app-schema-revision schema) 7)
(check-equal? (map keel:schema-record-name (keel:app-schema-records schema)) '("Profile"))
(check-equal? (map keel:schema-enum-name (keel:app-schema-enums schema)) '("AccessLevel"))
(check-equal? (map keel:schema-command-name (keel:app-schema-commands schema))
              '("fetch-profile" "profile-exists?"))
(check-equal? (map keel:schema-event-name (keel:app-schema-events schema)) '("profile-updated"))
(check-equal? (map keel:schema-state-name (keel:app-schema-states schema))
              '("active-profile" "signed-in?"))

(define command (car (keel:app-schema-commands schema)))
(check-equal? (keel:schema-command-error-codes command) '())
(check-equal? (keel:schema-command-result command)
              (keel:optional-type (keel:reference-type "Profile")))

(define encoded (keel:encode-app-schema schema))
(check-equal? encoded (keel:encode-app-schema schema) "Keel introspection encoding is deterministic")
(check-equal? (keel:decode-app-value encoded) (keel:app-schema->app-value schema))

;; Code generation isolates each application's mutable Rivet registry in a
;; fresh namespace, but it must still return canonical Keel schema values from
;; the one shared Keel module instance.
(define-values (codegen-commands codegen-events codegen-states
                                 codegen-records codegen-enums)
  (codegen:load-schema schema-matrix-backend #:id "rivet.codegen-test"))
(check-true (andmap keel:schema-command? codegen-commands))
(check-true (andmap keel:schema-event? codegen-events))
(check-true (andmap keel:schema-state? codegen-states))
(check-true (andmap keel:schema-record? codegen-records))
(check-true (andmap keel:schema-enum? codegen-enums))

(check-exn #rx"Unit is valid only as a command result"
           (lambda ()
             (backend-schema->app-schema (hash 'rpcs
                                               '()
                                               'events
                                               (list (hasheq 'name 'bad-event 'type 'Void))
                                               'states
                                               '()
                                               'records
                                               '()
                                               'enums
                                               '())
                                         #:id "invalid")))

;; Rivet enforces Keel's placement rule at declaration time so every valid
;; backend snapshot can be projected, rather than failing only in tooling.
(check-exn #rx"Void is valid only as an RPC result"
           (lambda ()
             (let ()
               (define-event invalid-event : (List Void))
               (void))))
(check-exn #rx"Void is valid only as an RPC result"
           (lambda ()
             (let ()
               (define-state invalid-state : (Optional Void) (void))
               (void))))
(check-exn #rx"Void is valid only as an RPC result"
           (lambda ()
             (let ()
               (define-record InvalidRecord
                              ((field :
                                      Void)))
               (void))))
(check-exn #rx"Void is valid only as an RPC result"
           (lambda ()
             (let ()
               (define-rpc (invalid-argument [value : (Optional Void)] : Bool) #f)
               (void))))
(check-exn #rx"Void is valid only as a direct RPC result"
           (lambda ()
             (let ()
               (define-rpc (invalid-result : (List Void)) '())
               (void))))
