#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         "../rivet-cli/codegen.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-codegen-~a" 'directory))

(define (write-backend! project-root source)
  (call-with-output-file
   (build-path project-root "app" "backend.rkt")
   #:exists 'truncate/replace
   (lambda (out) (display source out))))

(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "demo" temp-root))
    (define app-xaml
      (file->string (build-path project-root "windows" "App.xaml")))
    (define app-cpp
      (file->string (build-path project-root "windows" "App.xaml.cpp")))
    (define windows-project
      (file->string (build-path project-root "windows" "RivetHost.vcxproj")))
    (check-true (regexp-match? #rx"XamlControlsResources" app-xaml))
    (check-true
     (regexp-match? #rx"Windows::Foundation::IInspectable" app-cpp))
    (check-true (regexp-match? #rx"/utf-8" windows-project))

    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-event progress : Int64)
(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value Int64] : Int64)
  (add1 value))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )

    (define project (load-project project-root))
    (define schema (generate-clients! project))
    (check-equal? (length (first schema)) 2)
    (check-equal? (length (second schema)) 1)
    (check-equal? (length (third schema)) 1)

    (define swift
      (file->string
       (build-path project-root
                   "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")))
    (define cpp
      (file->string
       (build-path project-root "windows" "GeneratedBackend.hpp")))

    (check-true (regexp-match? #rx"func greet\\(name: String\\)" swift))
    (check-true (regexp-match? #rx"func increment\\(value: Int64\\)" swift))
    (check-true (regexp-match? #rx"case progress\\(Int64\\)" swift))
    (check-true (regexp-match? #rx"func getCounter\\(\\) async throws -> Int64" swift))
    (check-true (regexp-match? #rx"func setCounter\\(_ value: Int64\\)" swift))

    ;; Existing future APIs remain source-compatible.
    (check-true (regexp-match? #rx"std::future<std::string> greet" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> increment" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> get_counter\\(\\)" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> set_counter\\(std::int64_t value\\)" cpp))

    ;; Windows also gets typed, cancellable completion APIs with no blocking get().
    (check-true (regexp-match? #rx"struct Result" cpp))
    (check-true (regexp-match? #rx"std::uint64_t greet_async" cpp))
    (check-true (regexp-match? #rx"std::function<void\\(Result<std::string>\\)> completion" cpp))
    (check-true (regexp-match? #rx"std::uint64_t increment_async" cpp))
    (check-true (regexp-match? #rx"std::uint64_t get_counter_async" cpp))
    (check-true (regexp-match? #rx"std::uint64_t set_counter_async" cpp))
    (check-true (regexp-match? #rx"backend_\\.request_async" cpp))
    (check-true (regexp-match? #rx"backend_\\.get_state_async" cpp))
    (check-true (regexp-match? #rx"backend_\\.set_state_async" cpp))
    (check-true (regexp-match? #rx"struct ProgressEvent \\{ std::int64_t value; \\};" cpp))

    ;; Distinct Racket identifiers can normalize to the same native API name.
    ;; Codegen must reject these cases instead of emitting uncompilable Swift/C++.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-rpc (foo-bar [value Int64] : Int64) value)
(define-rpc (foo_bar [value Int64] : Int64) value)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; Generated async companions are part of the C++ API namespace too.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-rpc (foo [value Int64] : Int64) value)
(define-rpc (foo_async [value Int64] : Int64) value)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; The same guard applies to argument names inside a generated method.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-rpc (combine [foo-bar Int64] [foo_bar Int64] : Int64)
  (+ foo-bar foo_bar))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; Event case names are normalized too and need the same collision safety.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-event foo-bar : Int64)
(define-event foo_bar : Int64)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
