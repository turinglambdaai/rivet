#lang racket/base

;; Product-owned acceptance orchestration. Rivet deliberately does not invent
;; a cross-platform UI test DSL: every suite remains a native/Racket command,
;; while this module validates coverage and runs argv directly with bounded
;; time and output so an agent cannot turn prose into completion evidence.

(require json
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "project.rkt")

(provide default-acceptance-manifest-name
         acceptance-kinds
         supported-platforms
         (struct-out acceptance-suite)
         load-acceptance-manifest
         acceptance-report
         run-acceptance-command)

(define default-acceptance-manifest-name "rivet-acceptance.rktd")
(define acceptance-kinds
  '(unit contract bridge native-build native-ui package release))
(define supported-platforms '(windows macos linux))
(define maximum-captured-output-bytes (* 64 1024))

(struct acceptance-suite
  (id kind platforms command timeout-seconds evidence)
  #:transparent)

(define (current-platform)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else
     (raise-arguments-error 'acceptance-report
                            "unsupported acceptance platform"
                            "system-type" (system-type 'os))]))

(define (non-empty-string? value)
  (and (string? value) (positive? (string-length value))))

(define (safe-project-relative-path-string? value)
  (and (non-empty-string? value)
       (let* ([path (string->path value)]
              [parts (explode-path path)])
         (and (relative-path? path)
              (pair? parts)
              (andmap path? parts)
              (not (string-ci=? (path->string (car parts)) ".git"))))))

(define (manifest-error path message . fields)
  (apply raise-arguments-error
         'load-acceptance-manifest
         message
         "path" path
         fields))

(define (required-key path value key predicate expected)
  (define item
    (hash-ref value key
              (lambda ()
                (manifest-error path
                                "missing required acceptance setting"
                                "setting" key))))
  (unless (predicate item)
    (manifest-error path
                    "invalid acceptance setting"
                    "setting" key
                    "expected" expected
                    "value" item))
  item)

(define (valid-platform-list? value)
  (and (list? value)
       (pair? value)
       (andmap (lambda (item) (memq item supported-platforms)) value)
       (= (length value) (length (remove-duplicates value eq?)))))

(define (valid-command? value)
  (and (list? value)
       (pair? value)
       (andmap non-empty-string? value)))

(define (acceptance-evidence-path-string? value)
  (and (safe-project-relative-path-string? value)
       (let ([parts (explode-path (string->path value))])
         (and (>= (length parts) 3)
              (string-ci=? (path->string (first parts)) ".rivet")
              (string-ci=? (path->string (second parts)) "acceptance")))))

(define (valid-evidence? value)
  (and (list? value)
       (andmap acceptance-evidence-path-string? value)
       (= (length value) (length (remove-duplicates value string=?)))))

(define (parse-suite path raw)
  (unless (hash? raw)
    (manifest-error path "suite must be a hash" "value" raw))
  (define id
    (required-key
     path
     raw
     'id
     (lambda (value)
       (and (symbol? value)
            (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]*$"
                           (symbol->string value))))
     "symbol containing only letters, digits, '.', '-', or '_'"))
  (define kind
    (required-key path
                  raw
                  'kind
                  (lambda (value) (memq value acceptance-kinds))
                  acceptance-kinds))
  (define platforms
    (required-key path raw 'platforms valid-platform-list?
                  "non-empty unique subset of (windows macos linux)"))
  (define command
    (required-key path raw 'command valid-command?
                  "non-empty list of argv strings"))
  (define timeout-seconds (hash-ref raw 'timeout-seconds 900))
  (unless (and (exact-integer? timeout-seconds)
               (positive? timeout-seconds)
               (<= timeout-seconds 7200))
    (manifest-error path
                    "invalid suite timeout"
                    "suite" id
                    "expected" "integer from 1 through 7200"
                    "value" timeout-seconds))
  (define evidence (hash-ref raw 'evidence '()))
  (unless (valid-evidence? evidence)
    (manifest-error path
                    "invalid suite evidence"
                    "suite" id
                    "expected"
                    "unique file paths below .rivet/acceptance/"
                    "value" evidence))
  (when (and (memq kind '(native-ui package release))
             (null? evidence))
    (manifest-error path
                    "suite kind requires at least one evidence file"
                    "suite" id
                    "kind" kind))
  (acceptance-suite id kind platforms command timeout-seconds evidence))

(define (parse-requirement path raw)
  (unless (hash? raw)
    (manifest-error path "requirement must be a hash" "value" raw))
  (define kind
    (required-key path
                  raw
                  'kind
                  (lambda (value) (memq value acceptance-kinds))
                  acceptance-kinds))
  (define platforms
    (required-key path raw 'platforms valid-platform-list?
                  "non-empty unique subset of (windows macos linux)"))
  (cons kind platforms))

(define (suite-covers? suite kind platform)
  (and (eq? (acceptance-suite-kind suite) kind)
       (memq platform (acceptance-suite-platforms suite))))

(define (load-acceptance-manifest project
                                  [manifest default-acceptance-manifest-name])
  (unless (safe-project-relative-path-string? manifest)
    (raise-arguments-error 'load-acceptance-manifest
                           "manifest must be a project-relative path"
                           "manifest" manifest))
  (define path (project-path project manifest))
  (unless (file-exists? path)
    (raise-arguments-error 'load-acceptance-manifest
                           "acceptance manifest is missing"
                           "path" path
                           "fix"
                           "commit rivet-acceptance.rktd and run `raco rivet acceptance --json` in CI"))
  (define-values (raw trailing)
    (call-with-input-file
     path
     (lambda (input)
       (values (read input) (read input)))))
  (unless (eof-object? trailing)
    (manifest-error path
                    "acceptance manifest must contain exactly one value"
                    "trailing-value" trailing))
  (unless (hash? raw)
    (manifest-error path "acceptance manifest must contain a hash" "value" raw))
  (define version
    (required-key path raw 'version exact-integer? "integer"))
  (unless (= version 1)
    (manifest-error path
                    "unsupported acceptance manifest version"
                    "configured" version
                    "supported" 1))
  (define suites-raw
    (required-key path raw 'suites (lambda (value) (and (list? value) (pair? value)))
                  "non-empty list of suite hashes"))
  (define suites (map (lambda (suite) (parse-suite path suite)) suites-raw))
  (define ids (map acceptance-suite-id suites))
  (unless (= (length ids) (length (remove-duplicates ids eq?)))
    (manifest-error path "suite ids must be unique" "ids" ids))
  (define requirements-raw
    (required-key path raw 'requirements
                  (lambda (value) (and (list? value) (pair? value)))
                  "non-empty list of requirement hashes"))
  (define requirements (map (lambda (item) (parse-requirement path item))
                            requirements-raw))
  (define requirement-pairs
    (for*/list ([requirement (in-list requirements)]
                [platform (in-list (cdr requirement))])
      (cons (car requirement) platform)))
  (unless (= (length requirement-pairs)
             (length (remove-duplicates requirement-pairs equal?)))
    (manifest-error path
                    "requirement kind/platform pairs must be unique"
                    "requirements" requirement-pairs))
  (for* ([requirement (in-list requirements)]
         [platform (in-list (cdr requirement))])
    (unless (for/or ([suite (in-list suites)])
              (suite-covers? suite (car requirement) platform))
      (manifest-error path
                      "required acceptance coverage has no suite"
                      "kind" (car requirement)
                      "platform" platform)))
  (values path suites requirements))

(define (capture-port! port result)
  (define chunks '())
  (define captured 0)
  (define truncated? #f)
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (set-box! result
                    (cons (string->bytes/utf-8
                           (string-append "output capture failed: "
                                          (exn-message error)))
                          #f)))])
    (let loop ()
      (define chunk (read-bytes 4096 port))
      (unless (eof-object? chunk)
        (define remaining (- maximum-captured-output-bytes captured))
        (define keep (min remaining (bytes-length chunk)))
        (when (positive? keep)
          (set! chunks (cons (subbytes chunk 0 keep) chunks))
          (set! captured (+ captured keep)))
        (when (< keep (bytes-length chunk))
          (set! truncated? #t))
        ;; Always drain the child so a noisy suite cannot deadlock on a full
        ;; pipe after reaching the evidence bound.
        (loop)))
    (set-box! result (cons (apply bytes-append (reverse chunks)) truncated?)))
  (close-input-port port))

(define (captured-output->string result)
  (bytes->string/utf-8 (car (unbox result)) #\uFFFD))

(define (resolve-executable project raw)
  (define candidate (string->path raw))
  (define path-like?
    (or (complete-path? candidate)
        (regexp-match? #px"[/\\\\]" raw)))
  (define resolved
    (if path-like?
        (path->complete-path candidate (rivet-project-root project))
        (find-executable-path raw)))
  (unless (and resolved (file-exists? resolved))
    (raise-arguments-error 'acceptance-report
                           "suite executable was not found"
                           "executable" raw))
  resolved)

(define (prepare-evidence! project suite)
  ;; Evidence belongs under Rivet's generated root, so removing stale files is
  ;; both safe and necessary: an earlier green run must not satisfy this run.
  (for ([relative (in-list (acceptance-suite-evidence suite))])
    (define path (project-path project relative))
    (for/fold ([parent (rivet-project-root project)])
              ([part (in-list
                      (drop-right (explode-path (string->path relative)) 1))])
      (define next (build-path parent part))
      (when (link-exists? next)
        (raise-arguments-error 'acceptance-report
                               "suite evidence parent must not be a link"
                               "suite" (acceptance-suite-id suite)
                               "evidence" relative
                               "linked-parent" next))
      next)
    (when (directory-exists? path)
      (raise-arguments-error 'acceptance-report
                             "suite evidence must be a file, not a directory"
                             "suite" (acceptance-suite-id suite)
                             "evidence" relative))
    (when (file-exists? path)
      (delete-file path))))

(define (evidence-missing project suite)
  (for/list ([relative (in-list (acceptance-suite-evidence suite))]
             #:unless (file-exists? (project-path project relative)))
    relative))

(define (execute-suite project suite)
  (define command (acceptance-suite-command suite))
  (define executable (resolve-executable project (car command)))
  (define arguments (cdr command))
  (define stdout-result (box (cons #"" #f)))
  (define stderr-result (box (cons #"" #f)))
  (define process #f)
  (define stdout-thread #f)
  (define stderr-thread #f)
  (define started (current-inexact-monotonic-milliseconds))
  (define timed-out? #f)

  (define (finish-process!)
    (when process
      (when (eq? (subprocess-status process) 'running)
        (with-handlers ([exn:fail? void])
          (subprocess-kill process #t)))
      (subprocess-wait process))
    (when stdout-thread (thread-wait stdout-thread))
    (when stderr-thread (thread-wait stderr-thread)))

  (with-handlers
      ([exn:fail?
        (lambda (error)
          (finish-process!)
          (hash 'id (symbol->string (acceptance-suite-id suite))
                'kind (symbol->string (acceptance-suite-kind suite))
                'command (acceptance-suite-command suite)
                'evidence (acceptance-suite-evidence suite)
                'status "fail"
                'duration-ms
                (inexact->exact
                 (round (- (current-inexact-monotonic-milliseconds) started)))
                'exit-code 'null
                'timed-out #f
                'stdout ""
                'stderr (exn-message error)
                'stdout-truncated #f
                'stderr-truncated #f
                'missing-evidence '()))])
    (prepare-evidence! project suite)
    (define-values (child child-stdout child-stdin child-stderr)
      (parameterize ([current-directory (rivet-project-root project)])
        (apply subprocess #f #f #f executable arguments)))
    (set! process child)
    (close-output-port child-stdin)
    (set! stdout-thread
          (thread (lambda () (capture-port! child-stdout stdout-result))))
    (set! stderr-thread
          (thread (lambda () (capture-port! child-stderr stderr-result))))
    (unless (sync/timeout (acceptance-suite-timeout-seconds suite) process)
      (set! timed-out? #t))
    (finish-process!)
    (define exit-code (and (not timed-out?) (subprocess-status process)))
    (define missing (if (and (integer? exit-code) (zero? exit-code))
                        (evidence-missing project suite)
                        '()))
    (define passed?
      (and (not timed-out?)
           (integer? exit-code)
           (zero? exit-code)
           (null? missing)))
    (hash 'id (symbol->string (acceptance-suite-id suite))
          'kind (symbol->string (acceptance-suite-kind suite))
          'command (acceptance-suite-command suite)
          'evidence (acceptance-suite-evidence suite)
          'status (if passed? "pass" "fail")
          'duration-ms
          (inexact->exact
           (round (- (current-inexact-monotonic-milliseconds) started)))
          'exit-code (or exit-code 'null)
          'timed-out timed-out?
          'stdout (captured-output->string stdout-result)
          'stderr (captured-output->string stderr-result)
          'stdout-truncated (cdr (unbox stdout-result))
          'stderr-truncated (cdr (unbox stderr-result))
          'missing-evidence missing)))

(define (acceptance-report project
                           #:manifest [manifest default-acceptance-manifest-name]
                           #:suite [selected-suite #f]
                           #:platform [platform (current-platform)]
                           #:runner [runner execute-suite])
  (define-values (path suites requirements)
    (load-acceptance-manifest project manifest))
  (unless (memq platform supported-platforms)
    (raise-arguments-error 'acceptance-report
                           "unsupported requested platform"
                           "platform" platform))
  (when (and selected-suite
             (not (for/or ([suite (in-list suites)])
                    (eq? (acceptance-suite-id suite) selected-suite))))
    (raise-arguments-error 'acceptance-report
                           "requested suite is not declared"
                           "suite" selected-suite))
  (define applicable
    (for/list ([suite (in-list suites)]
               #:when (and (memq platform (acceptance-suite-platforms suite))
                           (or (not selected-suite)
                               (eq? selected-suite (acceptance-suite-id suite)))))
      suite))
  (when (null? applicable)
    (raise-arguments-error 'acceptance-report
                           "no acceptance suite applies to this platform"
                           "platform" platform
                           "selected-suite" selected-suite))
  (define results (map (lambda (suite) (runner project suite)) applicable))
  (define passed
    (count (lambda (result) (string=? (hash-ref result 'status) "pass"))
           results))
  (define failed (- (length results) passed))
  (hash 'format-version 1
        'project (project-name project)
        'platform (symbol->string platform)
        'manifest (path->string path)
        'configured-suites (length suites)
        'configured-requirements
        (for/list ([requirement (in-list requirements)])
          (hash 'kind (symbol->string (car requirement))
                'platforms (map symbol->string (cdr requirement))))
        'selected-suite (if selected-suite (symbol->string selected-suite) 'null)
        'status (if (zero? failed) "pass" "fail")
        'passed passed
        'failed failed
        'suites results))

(define (display-report report)
  (printf "Rivet acceptance: ~a on ~a — ~a passed, ~a failed\n"
          (hash-ref report 'project)
          (hash-ref report 'platform)
          (hash-ref report 'passed)
          (hash-ref report 'failed))
  (for ([result (in-list (hash-ref report 'suites))])
    (printf "  [~a] ~a (~a, ~a ms)\n"
            (hash-ref result 'status)
            (hash-ref result 'id)
            (hash-ref result 'kind)
            (hash-ref result 'duration-ms))
    (when (string=? (hash-ref result 'status) "fail")
      (unless (string=? (hash-ref result 'stdout) "")
        (printf "    stdout:\n~a\n" (hash-ref result 'stdout)))
      (unless (string=? (hash-ref result 'stderr) "")
        (printf "    stderr:\n~a\n" (hash-ref result 'stderr)))
      (unless (null? (hash-ref result 'missing-evidence))
        (printf "    missing evidence: ~a\n"
                (string-join (hash-ref result 'missing-evidence) ", "))))))

(define (parse-arguments args)
  (let loop ([remaining args]
             [json? #f]
             [manifest default-acceptance-manifest-name]
             [manifest-set? #f]
             [suite #f])
    (match remaining
      ['() (values json? manifest suite)]
      [(cons "--json" tail)
       (when json?
         (raise-arguments-error 'rivet-acceptance "duplicate --json option"))
       (loop tail #t manifest manifest-set? suite)]
      [(list* "--manifest" value tail)
       (when manifest-set?
         (raise-arguments-error 'rivet-acceptance "duplicate --manifest option"))
       (loop tail json? value #t suite)]
      [(list* "--suite" value tail)
       (when suite
         (raise-arguments-error 'rivet-acceptance "duplicate --suite option"))
       (loop tail json? manifest manifest-set? (string->symbol value))]
      [_
       (raise-arguments-error
        'rivet-acceptance
        "expected [--json] [--manifest <path>] [--suite <id>]"
        "arguments" args)])))

(define (run-acceptance-command project args)
  (define-values (json? manifest suite) (parse-arguments args))
  (define report
    (acceptance-report project #:manifest manifest #:suite suite))
  (if json?
      (begin
        (write-json report)
        (newline))
      (display-report report))
  (if (string=? (hash-ref report 'status) "pass") 0 1))
