#lang racket/base

;; Remote verification orchestration (issue #287). The local operating system
;; is an editing environment, not the boundary of verification: this command
;; triggers the per-platform acceptance legs of one commit on GitHub Actions,
;; waits for the dispatched runs, downloads the archived `acceptance --json`
;; reports, and folds them into the shared verification matrix. It drives the
;; `gh` CLI and nothing else, so workflow names and artifact names stay the
;; product's own conventions.

(require json
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         "acceptance.rkt"
         "matrix.rkt")

(provide run-verify-remote-command)

(define default-workflow "verify.yml")
(define default-artifact-prefix "acceptance-report-")
(define default-timeout-seconds 1800)
(define default-output-directory ".rivet/verify-remote")
(define run-list-poll-seconds 5)

(define usage-text
  (string-append
   "raco rivet verify-remote --repo OWNER/REPO --ref REF"
   " [--workflow verify.yml] [--platform linux]..."
   " [--artifact-prefix acceptance-report-]"
   " [--timeout-seconds 1800] [--output-directory DIR] [--json]"))

(define (verify-remote-error message . fields)
  (apply raise-arguments-error 'rivet-verify-remote message fields))

(define (non-empty-text? value)
  (and (string? value) (positive? (string-length value))))

(define (current-inexact-seconds)
  (/ (current-inexact-milliseconds) 1000.0))

;; One collected workflow run: how it concluded, which acceptance artifacts
;; it archived, and which loaded platform reports it produced.
(struct run-outcome (run-id conclusion reports detail) #:transparent)

;; One gh invocation: (values exit-code stdout stderr). The command never
;; decides trust from exit codes it did not see, so every caller funnels
;; through this injectable boundary. Tests parameterize `current-run-gh`
;; with a scripted replacement.
(define (default-run-gh argv)
  (define gh (find-executable-path "gh"))
  (unless gh
    (verify-remote-error
     "the gh CLI was not found on PATH"
     "fix" "install the GitHub CLI and authenticate with `gh auth login`"))
  (define-values (child stdout stdin stderr)
    (apply subprocess #f #f #f gh argv))
  (close-output-port stdin)
  (define stdout-thread (thread (lambda () (port->string stdout))))
  (define stderr-thread (thread (lambda () (port->string stderr))))
  (subprocess-wait child)
  (values (subprocess-status child)
          (thread-wait stdout-thread)
          (thread-wait stderr-thread)))

(define current-run-gh (make-parameter default-run-gh))

(define (trimmed text)
  (string-trim (or text "")))

(define (run-gh-must who argv)
  ;; who is the surrounding step; the failure detail carries gh's stderr.
  (define-values (code stdout stderr) ((current-run-gh) argv))
  (unless (zero? code)
    (verify-remote-error (format "~a failed" who)
                         "command" (string-join (cons "gh" argv) " ")
                         "detail" (trimmed stderr)))
  stdout)

(define (gh-json who stdout)
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (verify-remote-error "gh emitted unparseable JSON"
                               "command" who
                               "message" (exn-message error)))])
    (read-json (open-input-string stdout))))

(define (resolve-commit-sha repo ref)
  (define sha
    (trimmed
     (run-gh-must "commit resolution"
                  (list "api" (format "repos/~a/commits/~a" repo ref)
                        "--jq" ".sha"))))
  (unless (regexp-match? #px"^[0-9a-f]{40}$" sha)
    (verify-remote-error "commit resolution returned no commit sha"
                         "repo" repo
                         "ref" ref
                         "detail" sha))
  sha)

;; Dispatch runs are identified against this baseline so a concurrent
;; session's older runs can never be mistaken for this verification.
(define (listed-dispatch-runs repo workflow)
  (define runs
    (gh-json "gh run list"
             (run-gh-must
              "run listing"
              (list "run" "list"
                    "--repo" repo
                    "--workflow" workflow
                    "--event" "workflow_dispatch"
                    "--json" "databaseId,headSha"
                    "--limit" "50"))))
  (unless (list? runs)
    (verify-remote-error "gh run list returned no run array"
                         "repo" repo
                         "workflow" workflow))
  (for/list ([run (in-list runs)])
    (unless (and (hash? run)
                 (exact-integer? (hash-ref run 'databaseId #f))
                 (string? (hash-ref run 'headSha #f)))
      (verify-remote-error "gh run list returned a malformed run"
                           "repo" repo
                           "value" run))
    run))

(define (dispatch-platform repo workflow sha platform)
  (run-gh-must "workflow dispatch"
               (list "workflow" "run" workflow
                     "--repo" repo
                     "--ref" sha
                     "-f" (format "platform=~a" platform))))

(define (wait-for-dispatched-runs repo workflow sha baseline expected
                                  timeout-seconds sleep now)
  (define started (now))
  (let poll ()
    (define runs (listed-dispatch-runs repo workflow))
    (define discovered
      (remove-duplicates
       (for/list ([run (in-list runs)]
                  #:when (and (string=? (hash-ref run 'headSha) sha)
                              (not (member (hash-ref run 'databaseId)
                                           baseline =))))
         (hash-ref run 'databaseId))
       =))
    (cond
      [(>= (length discovered) expected) discovered]
      [(> (- (now) started) timeout-seconds)
       (verify-remote-error
        "dispatched verification runs never appeared"
        "workflow" workflow
        "commit" sha
        "expected-runs" expected
        "discovered-runs" (length discovered)
        "timeout-seconds" timeout-seconds)]
      [else (sleep run-list-poll-seconds) (poll)])))

;; A red run must still hand over its archived reports: the watch exit code
;; only sets the conclusion, never skips the download, because a failing
;; platform's evidence is exactly what the matrix exists to show.
(define (collect-run run-id repo artifact-prefix platforms output-directory)
  (define-values (watch-code _watch-stdout _watch-stderr)
    ((current-run-gh)
     (list "run" "watch" (number->string run-id)
           "--repo" repo
           "--exit-status"
           "--interval" "10")))
  (define conclusion (if (zero? watch-code) "success" "failure"))
  (define run-directory
    (build-path output-directory (format "run-~a" run-id)))
  ;; Stale artifacts from an earlier collection of the same run must not
  ;; satisfy this one, mirroring the evidence hygiene of acceptance suites.
  (when (directory-exists? run-directory)
    (delete-directory/files run-directory))
  (define-values (_dl-code _dl-stdout _dl-stderr)
    ((current-run-gh)
     (list "run" "download" (number->string run-id)
           "--repo" repo
           "--dir" (path->string run-directory))))
  (define artifact-directories
    (if (directory-exists? run-directory)
        (for/list ([entry (in-list (directory-list run-directory #:build? #t))]
                   #:when (directory-exists? entry))
          entry)
        '()))
  (define reports
    (append*
     (for*/list ([artifact-directory (in-list artifact-directories)]
                 [artifact (in-value
                            (path->string
                             (file-name-from-path artifact-directory)))]
                 [platform (in-list platforms)]
                 #:when (string=?
                         artifact
                         (string-append artifact-prefix
                                        (symbol->string platform))))
       (define json-paths
         (sort (find-files (lambda (path)
                             (equal? (path-get-extension path)
                                     #".json"))
                           artifact-directory)
               string<?
               #:key path->string))
       (unless (pair? json-paths)
         (verify-remote-error
          "the archived acceptance artifact contains no JSON report"
          "artifact" artifact))
       (for/list ([path (in-list json-paths)])
         (hash 'platform (symbol->string platform)
               'path (path->string path)
               'report (load-acceptance-report path))))))
  (run-outcome run-id conclusion reports
               (if (zero? watch-code) #f (format "run concluded ~a" conclusion))))

(define (parse-arguments args)
  (let loop ([remaining args]
             [repo #f]
             [ref #f]
             [workflow default-workflow]
             [platforms '()]
             [artifact-prefix default-artifact-prefix]
             [timeout-seconds default-timeout-seconds]
             [output-directory default-output-directory]
             [json? #f])
    (match remaining
      ['()
       (unless repo
         (verify-remote-error "missing required --repo option"
                              "usage" usage-text))
       (unless ref
         (verify-remote-error "missing required --ref option"
                              "usage" usage-text))
       (define requested
         (remove-duplicates (reverse (map string->symbol platforms)) eq?))
       (for ([platform (in-list requested)])
         (unless (memq platform supported-platforms)
           (verify-remote-error "unknown --platform"
                                "expected"
                                (map symbol->string supported-platforms)
                                "value" platform)))
       (unless (and (exact-integer? timeout-seconds)
                    (positive? timeout-seconds))
         (verify-remote-error "invalid --timeout-seconds"
                              "expected" "positive integer"
                              "value" timeout-seconds))
       (values repo
               ref
               workflow
               (if (null? requested) supported-platforms requested)
               artifact-prefix
               timeout-seconds
               output-directory
               json?)]
      [(list* "--repo" value tail)
       (when repo (verify-remote-error "duplicate --repo option"))
       (unless (regexp-match? #px"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$" value)
         (verify-remote-error "invalid --repo"
                              "expected" "OWNER/REPO"
                              "value" value))
       (loop tail value ref workflow platforms artifact-prefix
             timeout-seconds output-directory json?)]
      [(list* "--ref" value tail)
       (when ref (verify-remote-error "duplicate --ref option"))
       (unless (non-empty-text? value)
         (verify-remote-error "invalid --ref" "value" value))
       (loop tail repo value workflow platforms artifact-prefix
             timeout-seconds output-directory json?)]
      [(list* "--workflow" value tail)
       (unless (non-empty-text? value)
         (verify-remote-error "invalid --workflow" "value" value))
       (loop tail repo ref value platforms artifact-prefix
             timeout-seconds output-directory json?)]
      [(list* "--platform" value tail)
       (loop tail repo ref workflow (cons value platforms) artifact-prefix
             timeout-seconds output-directory json?)]
      [(list* "--artifact-prefix" value tail)
       (unless (non-empty-text? value)
         (verify-remote-error "invalid --artifact-prefix" "value" value))
       (loop tail repo ref workflow platforms value
             timeout-seconds output-directory json?)]
      [(list* "--timeout-seconds" value tail)
       (define parsed
         (and (string? value)
              (regexp-match? #px"^[0-9]+$" value)
              (string->number value)))
       (loop tail repo ref workflow platforms artifact-prefix
             parsed output-directory json?)]
      [(list* "--output-directory" value tail)
       (unless (non-empty-text? value)
         (verify-remote-error "invalid --output-directory" "value" value))
       (loop tail repo ref workflow platforms artifact-prefix
             timeout-seconds value json?)]
      [(cons "--json" tail)
       (when json? (verify-remote-error "duplicate --json option"))
       (loop tail repo ref workflow platforms artifact-prefix
             timeout-seconds output-directory #t)]
      [_
       (verify-remote-error "unexpected argument"
                            "usage" usage-text
                            "arguments" args)])))

(define (display-outcomes repo ref sha workflow outcomes)
  (printf "Rivet remote verification: ~a @ ~a (~a)\n"
          repo (substring sha 0 (min 12 (string-length sha))) workflow)
  (for ([outcome (in-list outcomes)])
    (define platforms
      (remove-duplicates
       (map (lambda (report) (hash-ref report 'platform))
            (run-outcome-reports outcome))))
    (printf "  run ~a: ~a\n"
            (run-outcome-run-id outcome)
            (if (null? platforms)
                (or (run-outcome-detail outcome) "no acceptance artifacts")
                (format "~a — ~a, ~a report~a"
                        (string-join platforms ", ")
                        (or (run-outcome-detail outcome) "success")
                        (length (run-outcome-reports outcome))
                        (if (= (length (run-outcome-reports outcome)) 1)
                            ""
                            "s"))))))

(define (run-verify-remote-command args
                                   #:run-gh [run-gh default-run-gh]
                                   #:sleep [wake-after
                                            (lambda (seconds)
                                              (sleep seconds))]
                                   #:now [now current-inexact-seconds])
  (define-values (repo ref workflow platforms artifact-prefix
                       timeout-seconds output-directory json?)
    (parse-arguments args))
  ;; Bind the injectable boundary once so every helper sees the same scripted
  ;; gh during tests.
  (parameterize ([current-run-gh run-gh])
    (define sha (resolve-commit-sha repo ref))
    (define baseline
      (map (lambda (run) (hash-ref run 'databaseId))
           (listed-dispatch-runs repo workflow)))
    ;; Dispatch one leg per platform, then discover the runs those
    ;; dispatches produced. Collection keys off artifact names, so a
    ;; product's matrix workflow may name its jobs however it likes.
    (for ([platform (in-list platforms)])
      (dispatch-platform repo workflow sha platform))
    (define run-ids
      (wait-for-dispatched-runs repo workflow sha baseline (length platforms)
                                timeout-seconds wake-after now))
    ;; Nothing is written until the runs exist: a failed dispatch or a
    ;; timeout leaves no empty output directory behind.
    (make-directory* output-directory)
    (define outcomes
      (for/list ([run-id (in-list (sort run-ids <))])
        (with-handlers
            ([exn:fail?
              (lambda (error)
                (run-outcome run-id "collection-failed" '()
                             (exn-message error)))])
          (collect-run run-id repo artifact-prefix platforms
                       output-directory))))
    (define loaded-reports
      (append* (map (lambda (outcome) (run-outcome-reports outcome))
                    outcomes)))
    (define covered
      (remove-duplicates
       (map (lambda (report) (hash-ref report 'platform))
            loaded-reports)))
    (define uncovered
      (for/list ([platform (in-list platforms)]
                 #:unless (member (symbol->string platform) covered))
        (symbol->string platform)))
    (define matrix
      (and (pair? loaded-reports)
           (matrix-report (map (lambda (report)
                                 (hash-ref report 'report))
                               loaded-reports))))
    (cond
      [json?
       (write-json
        (hash 'format-version 1
              'repo repo
              'ref ref
              'sha sha
              'workflow workflow
              'runs (for/list ([outcome (in-list outcomes)])
                      (hash 'run-id (run-outcome-run-id outcome)
                            'conclusion (run-outcome-conclusion outcome)
                            'detail (or (run-outcome-detail outcome) 'null)
                            'reports (for/list ([report
                                                 (in-list
                                                  (run-outcome-reports
                                                   outcome))])
                                       (hash 'platform
                                             (hash-ref report 'platform)
                                             'path (hash-ref report 'path)))))
              'matrix (or matrix 'null)))
       (newline)]
      [else
       (display-outcomes repo ref sha workflow outcomes)
       (unless (null? uncovered)
         (printf "  missing platform legs: ~a\n" (string-join uncovered ", ")))
       (when matrix
         (display-matrix matrix))])
    (if (and matrix
             (string=? (hash-ref matrix 'status) "pass")
             (null? uncovered)
             (not (findf (lambda (outcome)
                           (string=? (run-outcome-conclusion outcome)
                                     "collection-failed"))
                         outcomes)))
        0
        1)))
