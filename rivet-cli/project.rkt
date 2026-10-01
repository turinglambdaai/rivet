#lang racket/base

(require racket/file
         racket/list
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
         project-publisher
         project-version
         project-build
         project-identifier
         project-release-channel
         project-url-schemes
         project-file-associations
         project-resources
         project-device-rpcs
         project-windows-icon
         project-macos-icon
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

(define generated-root-names '(".git" ".rivet" "build" "dist"))

(define (safe-project-relative-path-string? value)
  (and (string? value)
       (positive? (string-length value))
       (let* ([path (string->path value)]
              [parts (explode-path path)])
         (and (relative-path? path)
              (pair? parts)
              (andmap path? parts)
              (not (member (string-downcase
                            (path->string (car parts)))
                           generated-root-names))))))

(define (path-string-has-extension? value extension)
  (and (safe-project-relative-path-string? value)
       (let ([suffix (path-get-extension (string->path value))])
         (and suffix
              (string-ci=? (bytes->string/utf-8 suffix) extension)))))

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
            (lambda (v)
              (and (exact-integer? v)
                   (positive? v)
                   (<= v #x7fffffffffffffff)))
            "positive signed 64-bit integer")
  (optional 'display-name non-empty-string? "non-empty string")
  (optional 'publisher non-empty-string? "non-empty publisher string")
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
  (optional 'release-channel
            (lambda (v) (memq v '(stable beta dev)))
            "one of stable, beta, or dev")
  (optional 'url-schemes
            (lambda (v)
              (and (list? v)
                   (andmap (lambda (item)
                             (and (string? item)
                                  (regexp-match? #px"^[A-Za-z][A-Za-z0-9+.-]*$" item)))
                           v)))
            "list of RFC 3986 URL scheme strings")
  (optional 'file-associations
            (lambda (v)
              (and (list? v)
                   (andmap
                    (lambda (item)
                      (and (hash? item)
                           (string? (hash-ref item 'extension #f))
                           (regexp-match? #px"^\\.[A-Za-z0-9][A-Za-z0-9._-]*$"
                                          (hash-ref item 'extension))))
                    v)))
            "list of hashes containing an extension such as .rivet")
  (optional 'resources
            (lambda (v)
              (and (list? v)
                   (andmap safe-project-relative-path-string? v)
                   (= (length v) (length (remove-duplicates v string-ci=?)))))
            "list of unique project-relative file or directory paths outside .git, .rivet, build, and dist")
  (optional 'device-rpcs
            (lambda (v)
              (and (list? v)
                   (andmap
                    (lambda (name)
                      (and (symbol? name)
                           (let ([raw (symbol->string name)])
                             (and (positive? (string-length raw))
                                  (<= (bytes-length (string->bytes/utf-8 raw)) 124)
                                  (regexp-match? #px"^[A-Za-z0-9._-]+$" raw)))))
                    v)
                   (= (length v) (length (remove-duplicates v eq?)))))
            "unique RPC symbols whose names contain only letters, digits, '.', '-', or '_' and fit a device route")
  (optional 'windows-icon
            (lambda (v) (path-string-has-extension? v ".ico"))
            "project-relative .ico path")
  (optional 'macos-icon
            (lambda (v) (path-string-has-extension? v ".icns"))
            "project-relative .icns path")
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

(define (project-publisher project)
  (project-ref project
               'publisher
               (lambda () (project-display-name project))))

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

(define (project-release-channel project)
  (project-ref project 'release-channel (lambda () 'stable)))

(define (project-url-schemes project)
  (project-ref project 'url-schemes (lambda () '())))

(define (project-file-associations project)
  (project-ref project 'file-associations (lambda () '())))

(define (project-resources project)
  (project-ref project 'resources (lambda () '())))

(define (project-device-rpcs project)
  (project-ref project 'device-rpcs (lambda () '())))

(define (project-windows-icon project)
  (project-ref project 'windows-icon (lambda () #f)))

(define (project-macos-icon project)
  (project-ref project 'macos-icon (lambda () #f)))

(define (project-macos-min-version project)
  (project-ref project
               'macos-min-version
               (lambda () default-macos-min-version)))

(define (project-windows-min-version project)
  (project-ref project
               'windows-min-version
               (lambda () default-windows-min-version)))
