#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         "../rivet-cli/codegen.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-codegen-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "demo" temp-root))
    (call-with-output-file
     (build-path project-root "app" "backend.rkt")
     #:exists 'truncate/replace
     (lambda (out)
       (display
        #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-record User
  ([id : Int64]
   [display-name : String]
   [nickname : (Optional String)]))

(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value Int64] : Int64)
  (add1 value))

(define-rpc (echo-user [user : User] : User)
  user)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
        out)))

    (define project (load-project project-root))
    (define schema (generate-clients! project))
    (check-equal? (length (first schema)) 3)
    (check-equal? (length (second schema)) 1)
    (check-equal? (length (third schema)) 1)

    (define swift
      (file->string
       (build-path project-root
                   "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")))
    (define cpp
      (file->string
       (build-path project-root "windows" "GeneratedBackend.hpp")))

    (check-true (regexp-match? #rx"public struct User: Sendable" swift))
    (check-true (regexp-match? #rx"public let display_name: String" swift))
    (check-true (regexp-match? #rx"public let nickname: String\\?" swift))
    (check-true (regexp-match? #rx"func echo_user\\(user: User\\) async throws -> User" swift))
    (check-true (regexp-match? #rx"func greet\\(name: String\\)" swift))
    (check-true (regexp-match? #rx"func increment\\(value: Int64\\)" swift))
    (check-true (regexp-match? #rx"func getCounter\\(\\) async throws -> Int64" swift))
    (check-true (regexp-match? #rx"func setCounter\\(_ value: Int64\\)" swift))

    (check-true (regexp-match? #rx"struct User" cpp))
    (check-true (regexp-match? #rx"std::string display_name;" cpp))
    (check-true (regexp-match? #rx"std::optional<std::string> nickname;" cpp))
    (check-true (regexp-match? #rx"std::future<User> echo_user\\(User user\\)" cpp))
    (check-true (regexp-match? #rx"std::future<std::string> greet" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> increment" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> get_counter\\(\\)" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> set_counter\\(std::int64_t value\\)" cpp)))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
