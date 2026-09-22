#lang racket/base

(require racket/file
         racket/path
         racket/string)

(provide (struct-out rivet-project)
         default-project-version
         default-project-build
         default-macos-min-version
         default-windows-min-version
         default-project-identifier
         find-project
         load-project
         project-ref
         project-path
         project-name
         project-display-name
         project-version
         project-build
         project-identifier
         project-macos-min-version
         project-windows-min-version)

(struct rivet-project (root config) #:transparent)

(define config-name "rivet.rktd")
(define default-project-version "0.1.0")
(define default-project-build 1)
(define default-macos-min-version "14.0")
(define default-windows-min-version "10.0.19041.0")

(define (default-project-identifier name)
  (string-append
   "dev.rivet."
   (regexp-replace* #px"[^a-z0-9.-]"
                    (string-downcase name)
                    "-")))

(define (macos-version-string? value)
  (and (string? value)
       (regexp-match? #px"^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$" value)))

(define (windows-version-string? value)
  (and (string? value)
       (regexp-match? #px"^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$" value)))

(define (validate-config path value)
  (define (required key predicate description)
    (define item
      (hash-ref value key
                (lambda ()
                  (raise-arguments-error 'load-project
                                         "missing required project setting"
                                         "path" path
                                         "setting" key))))
    (unless (predicate item)
      (raise-arguments-error 'load-project
                             "invalid project setting"
                             "path" path
                             "setting" key
                             "expected" description
                             "value" item))
    item)

  (define (optional key predicate description)
    (when (hash-has-key? value key)
      (define item (hash-ref value key))
      (unless (predicate item)
        (raise-arguments-error 'load-project
                               "invalid project setting"
                               "path" path
                               "setting" key
                               "expected" description
                               "value" item))))

  (define non-empty-string?
    (lambda (v) (and (string? v) (positive? (string-length v)))))

  (required 'name non-empty-string? "non-empty string")
  (define backend
    (required 'backend
              (lambda (v)
                (and (string? v)
                     (positive? (string-length v))
                     (relative-path? (string->path v))))
              "non-empty relative path string"))
  (void backend)
  (required 'module non-empty-string? "non-empty string")
  (required 'entry non-empty-string? "non-empty string")
  (define protocol
    (required 'protocol exact-integer? "integer"))
  (unless (= protocol 1)
    (raise-arguments-error 'load-project
                           "unsupported Rivet project protocol"
                           "path" path
                           "configured" protocol
                           "supported" 1))

  ;; Release/platform metadata is optional for compatibility with 0.1
  ;; projects. New projects include it so build and packaging consume one
  ;; project-level source of truth instead of native-template literals.
  (optional 'version non-empty-string? "non-empty version string")
  (optional 'build
            (lambda (v) (and (exact-integer? v) (positive? v)))
            "positive integer")
  (optional 'display-name non-empty-string? "non-empty string")
  (optional 'identifier
            (lambda (v)
              (and (string? v)
                   (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9.-]*$" v)))
            "bundle/application identifier containing letters, digits, '.' or '-'")
  (optional 'macos-min-version
            macos-version-string?
            "macOS version with two or three numeric components, for example 14.0")
  (optional 'windows-min-version
            windows-version-string?
            "Windows version with four numeric components, for example 10.0.19041.0")
  value)

(define (load-config path)
  (define value
    (call-with-input-file path
      (lambda (in) (read in))))
  (unless (hash? value)
    (raise-arguments-error 'load-project
                           "rivet.rktd must contain a hash"
                           "path" path
                           "value" value))
  (validate-config path value))

(define (load-project root)
  (define complete (simplify-path (path->complete-path root) #t))
  (define config-path (build-path complete config-name))
  (unless (file-exists? config-path)
    (raise-arguments-error 'load-project
                           "not a Rivet project (rivet.rktd is missing)"
                           "directory" complete))
  (rivet-project complete (load-config config-path)))

(define (find-project [start (current-directory)])
  (let loop ([dir (simplify-path (path->complete-path start) #t)])
    (define config-path (build-path dir config-name))
    (cond
      [(file-exists? config-path) (load-project dir)]
      [else
       (define parent (simplify-path (build-path dir 'up) #t))
       (and (not (equal? parent dir))
            (loop parent))])))

(define (project-ref project key [failure-thunk #f])
  (hash-ref (rivet-project-config project)
            key
            (or failure-thunk
                (lambda ()
                  (raise-arguments-error
                   'project-ref
                   "missing required Rivet project setting"
                   "key" key
                   "project" (rivet-project-root project))))))

(define (project-path project . pieces)
  (apply build-path (rivet-project-root project) pieces))

(define (project-name project)
  (project-ref project 'name))

(define (project-display-name project)
  (project-ref project
               'display-name
               (lambda () (project-name project))))

(define (project-version project)
  (project-ref project
               'version
               (lambda () default-project-version)))

(define (project-build project)
  (project-ref project
               'build
               (lambda () default-project-build)))

(define (project-identifier project)
  (project-ref project
               'identifier
               (lambda () (default-project-identifier (project-name project)))))

(define (project-macos-min-version project)
  (project-ref project
               'macos-min-version
               (lambda () default-macos-min-version)))

(define (project-windows-min-version project)
  (project-ref project
               'windows-min-version
               (lambda () default-windows-min-version)))
