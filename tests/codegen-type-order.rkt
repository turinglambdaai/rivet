#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../rivet-cli/codegen.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-codegen-order-~a" 'directory))

(define (match-position rx text)
  (define matches (regexp-match-positions rx text))
  (and matches (caar matches)))

(define (check-before earlier-rx later-rx text)
  (define earlier (match-position earlier-rx text))
  (define later (match-position later-rx text))
  (check-not-false earlier)
  (check-not-false later)
  (check-true (< earlier later)))

(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "order" temp-root))
    (copy-file (build-path (current-directory)
                           "tests" "fixtures" "schema-matrix-backend.rkt")
               (build-path project-root "app" "backend.rkt")
               #t)
    (generate-clients! (load-project project-root))
    (define cpp
      (file->string (build-path project-root "windows" "GeneratedBackend.hpp")))

    ;; C++ requires a helper to be declared before another inline helper calls
    ;; it. Inner container helpers therefore must precede their outer types.
    (check-before #rx"rivet::Value encode__Optional_String_"
                  #rx"rivet::Value encode__List_Optional_String_"
                  cpp)
    (check-before #rx"rivet::Value encode__List_Int64_"
                  #rx"rivet::Value encode__Optional_List_Int64_"
                  cpp)
    (check-before #rx"decode__Optional_String_"
                  #rx"decode__List_Optional_String_"
                  cpp)
    (check-before #rx"decode__List_Int64_"
                  #rx"decode__Optional_List_Int64_"
                  cpp))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
