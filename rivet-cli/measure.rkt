#lang racket/base

;; Measurement for host apps (issue #262). The migration docs defined stop
;; rules referencing startup/package-size/latency thresholds, so release CI
;; needs one command that reports what a packaged app actually weighs and
;; whether it still fits its budgets. Size is fully deterministic here;
;; startup wraps the launch-smoke survival window; per-RPC latency stays
;; with the integration benchmarks (docs/benchmarks.md --benchmark mode),
;; which already measure the real embedded runtime end to end.

(require file/glob
         json
         racket/file
         racket/list
         racket/format
         racket/match
         racket/path
         racket/string
         "launch-smoke.rkt"
         "project.rkt")

(provide measure-size
         measure-startup
         parse-budget-file)

(define dist-directory "dist")

(define (dist-artifacts root)
  (define dist (build-path root dist-directory))
  (if (directory-exists? dist)
      (sort
       (for/list ([path (in-list (directory-list dist #:build? #t))]
                  #:when (file-exists? path))
         path)
       #:key path->string
       string<?)
      '()))

(define (format-bytes count)
  (define mb (/ count 1024.0 1024.0))
  (if (>= mb 1.0)
      (format "~a (~a MiB)" count (~r mb #:precision 1))
      (format "~a bytes" count)))

;; Budget files are JSON: {"rules": [{"glob": "*.dmg", "max-bytes":
;; 100000000}, ...]}. The first matching rule wins, so list the most
;; specific glob first.
(define (parse-budget-file path)
  (unless (file-exists? path)
    (error 'measure "budget file ~a does not exist" path))
  (define document
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (error 'measure "budget file ~a is not valid JSON: ~a"
                              path (exn-message e)))])
      (call-with-input-file path read-json)))
  (define rules (hash-ref document 'rules (lambda () #f)))
  (unless (and (list? rules)
               (for/and ([rule (in-list rules)])
                 (and (hash? rule)
                      (string? (hash-ref rule 'glob (lambda () #f)))
                      (exact-positive-integer?
                       (hash-ref rule 'max-bytes (lambda () #f))))))
    (error 'measure
           "budget file ~a must contain {\"rules\": [{\"glob\": ..., \"max-bytes\": ...}, ...]}"
           path))
  rules)

(define (budget-for rules artifact)
  (define name (path->string (file-name-from-path artifact)))
  (for/first ([rule (in-list rules)]
              #:when (glob-match? (hash-ref rule 'glob) name))
    (hash-ref rule 'max-bytes)))

(define (measure-size project
                      #:budget-path [budget-path #f]
                      #:artifact [artifact-filter #f])
  (define root (rivet-project-root project))
  (define artifacts
    (if artifact-filter
        (filter (lambda (path)
                  (equal? (path->string (file-name-from-path path))
                          artifact-filter))
                (dist-artifacts root))
        (dist-artifacts root)))
  (when (null? artifacts)
    (error 'measure
           "no packaged artifacts under ~a; run `raco rivet package` or `raco rivet release` first"
           (build-path root dist-directory)))
  (define rules (and budget-path (parse-budget-file budget-path)))
  (define violations '())
  (define rows
    (for/list ([artifact (in-list artifacts)])
      (define bytes (file-size artifact))
      (define budget (and rules (budget-for rules artifact)))
      (when (and budget (> bytes budget))
        (set! violations
              (cons (cons artifact (cons bytes budget)) violations)))
      (hash 'name (path->string (file-name-from-path artifact))
            'bytes bytes
            'budget-bytes budget)))
  (hash 'artifacts (reverse rows)
        'violations (reverse violations)))

(define (display-size-report report)
  (for ([row (in-list (hash-ref report 'artifacts))])
    (define budget (hash-ref row 'budget-bytes))
    (printf "  ~a: ~a~a\n"
            (hash-ref row 'name)
            (format-bytes (hash-ref row 'bytes))
            (if budget
                (format " [budget ~a]" (format-bytes budget))
                "")))
  (for ([violation (in-list (hash-ref report 'violations))])
    (define artifact (car violation))
    (define bytes (car (cdr violation)))
    (define budget (cdr (cdr violation)))
    (printf "  OVER BUDGET: ~a is ~a against a ~a budget\n"
            (path->string (file-name-from-path artifact))
            (format-bytes bytes)
            (format-bytes budget))))

(define (measure-startup project
                         #:artifact [artifact-filter #f]
                         #:seconds [seconds 5.0])
  (define root (rivet-project-root project))
  (define artifacts
    (if artifact-filter
        (filter (lambda (path)
                  (equal? (path->string (file-name-from-path path))
                          artifact-filter))
                (dist-artifacts root))
        (dist-artifacts root)))
  (when (null? artifacts)
    (error 'measure
           "no packaged artifacts under ~a; run `raco rivet package` first"
           (build-path root dist-directory)))
  ;; The most recent packaged GUI artifact is the smoke subject; dist keeps
  ;; manifests and SBOMs too, so pick the largest executable-like file.
  (define artifact
    (argmax file-size
            (filter (lambda (path)
                      (not (regexp-match? #rx"[.](json|txt|sha256|sig|zip)$"
                                          (path->string path))))
                    artifacts)))
  (define started (current-inexact-milliseconds))
  (launch-smoke! artifact
                 #:seconds seconds
                 #:who 'measure-startup)
  (define elapsed (/ (- (current-inexact-milliseconds) started) 1000.0))
  (hash 'artifact (path->string (file-name-from-path artifact))
        'survival-seconds elapsed
        'required-seconds seconds))

(define (display-startup-report report)
  (printf "  ~a survived its ~a second launch window (~a elapsed)\n"
          (hash-ref report 'artifact)
          (hash-ref report 'required-seconds)
          (~r (hash-ref report 'survival-seconds) #:precision 2)))

(define (run-measure args)
  (define find-project
    (dynamic-require "project.rkt" 'find-project))
  (define project
    (or (find-project)
        (error 'rivet "no rivet.rktd found in this directory or its parents")))
  (match args
    [(list "size")
     (define report (measure-size project))
     (display-size-report report)
     (unless (null? (hash-ref report 'violations))
       (error 'measure "size budgets exceeded; see the OVER BUDGET lines above"))]
    [(list "size" "--budget" budget-path)
     (define report (measure-size project #:budget-path budget-path))
     (display-size-report report)
     (unless (null? (hash-ref report 'violations))
       (error 'measure "size budgets exceeded; see the OVER BUDGET lines above"))]
    [(list "size" "--artifact" artifact)
     (display-size-report (measure-size project #:artifact artifact))]
    [(list "startup")
     (display-startup-report (measure-startup project))]
    [(list "startup" "--artifact" artifact)
     (display-startup-report (measure-startup project #:artifact artifact))]
    [(list "startup" "--seconds" seconds-text)
     (define seconds
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (string->number seconds-text)))
     (unless (and (real? seconds) (positive? seconds))
       (error 'measure "--seconds requires a positive number"))
     (display-startup-report (measure-startup project #:seconds seconds))]
    [_
     (error 'measure
            "unknown measurement ~a; use `size [--budget <file>] [--artifact <name>]` or `startup [--artifact <name>] [--seconds N]`"
            (string-join (if (null? args) '("(none)") args) " "))]))

(provide run-measure)
