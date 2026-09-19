#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../rivet-cli/codegen.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-codegen-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "demo" temp-root))
    (define project (load-project project-root))
    (define infos (generate-clients! project))

    (check-equal? (length infos) 2)

    (define swift
      (file->string
       (build-path project-root
                   "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")))
    (define cpp
      (file->string
       (build-path project-root "windows" "GeneratedBackend.hpp")))

    (check-true (regexp-match? #rx"func greet\\(name: String\\)" swift))
    (check-true (regexp-match? #rx"func increment\\(value: Int64\\)" swift))
    (check-true (regexp-match? #rx"std::future<std::string> greet" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> increment" cpp)))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
