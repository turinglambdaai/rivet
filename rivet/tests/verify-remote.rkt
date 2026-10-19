#lang racket/base

;; Remote verification orchestration (issue #287): the command scripts the
;; gh CLI end to end, downloads artifact-shaped reports onto the real
;; filesystem, and proves the matrix verdict plus the orchestration exit
;; code on every leg outcome.

(require json
         rackunit
         racket/file
         racket/list
         racket/match
         racket/port
         racket/string
         "../../rivet-cli/verify-remote.rkt")

(define sha-under-test (make-string 40 #\a))

(define (report-text platform status
                     [requirement-platforms (list "windows" "macos" "linux")])
  (jsexpr->string
   (hasheq 'format-version 1
           'project "demo"
           'platform platform
           'manifest "rivet-acceptance.rktd"
           'configured-suites 1
           'configured-requirements
           (list (hasheq 'kind "native-ui"
                         'platforms requirement-platforms))
           'selected-suite 'null
           'status status
           'passed (if (string=? status "pass") 1 0)
           'failed (if (string=? status "pass") 0 1)
           'suites
           (list (hasheq 'id (string-append platform "-ui")
                         'kind "native-ui"
                         'status status)))))

;; Builds the injectable gh boundary: records every invocation, replays the
;; run list progression, and materializes archived artifacts as real files so
;; the collection path runs for real.
(define (make-fake-gh!
         #:runs-before [runs-before "[]"]
         #:runs-after [runs-after "[]"]
         #:runs-after-on-call [runs-after-on-call 2]
         #:watch-codes [watch-codes (hash)]
         #:artifacts-by-run [artifacts-by-run (hash)]
         #:dispatch-code [dispatch-code 0]
         #:log [log #f])
  (define run-list-calls 0)
  (define (flag-value argv flag)
    (let loop ([rest argv])
      (match rest
        [(list (== flag) next _ ...) next]
        [(cons _ tail) (loop tail)]
        [_ #f])))
  (lambda (argv)
    (when log (log argv))
    (match argv
      [(list "api" _ "--jq" ".sha")
       (values 0 sha-under-test "")]
      [(list "run" "list" _ ...)
       (set! run-list-calls (+ run-list-calls 1))
       (values 0
               (if (>= run-list-calls runs-after-on-call)
                   runs-after
                   runs-before)
               "")]
      [(list "workflow" "run" _ ...)
       (if (zero? dispatch-code)
           (values 0 "" "")
           (values dispatch-code "" "no workflow_dispatch trigger"))]
      [(list "run" "watch" raw-id _ ...)
       (define run-id (string->number raw-id))
       (values (hash-ref watch-codes run-id 0) "" "")]
      [(list "run" "download" raw-id _ ...)
       (define run-id (string->number raw-id))
       (define directory
         (and run-id (flag-value argv "--dir")))
       (for ([spec (in-list (hash-ref artifacts-by-run run-id '()))]
             #:when directory)
         (define artifact-directory
           (build-path (string->path directory)
                       (string-append "acceptance-report-"
                                      (car spec))))
         (make-directory* artifact-directory)
         (call-with-output-file
          (build-path artifact-directory "report.json")
          (lambda (output) (display (cdr spec) output))
          #:exists 'truncate/replace))
       (values 0 "" "")]
      [_
       (values 1 "" (format "unexpected gh invocation: ~a" argv))])))

(define (all-green-artifacts)
  (hash 101 (list (cons "linux" (report-text "linux" "pass")))
        102 (list (cons "macos" (report-text "macos" "pass")))
        103 (list (cons "windows" (report-text "windows" "pass")))))

(define (green-runs-json)
  (jsexpr->string
   (list (hasheq 'databaseId 101 'headSha sha-under-test)
         (hasheq 'databaseId 102 'headSha sha-under-test)
         (hasheq 'databaseId 103 'headSha sha-under-test))))

(define (capture-output thunk)
  (define out (open-output-string))
  (define exit-code
    (parameterize ([current-output-port out]) (thunk)))
  (values exit-code (get-output-string out)))

(define (sleep-counter)
  (define count 0)
  (values (lambda (_) (set! count (+ count 1)))
          (lambda () count)))

;; Three green legs fold into a passing matrix and exit 0.
(let-values ([(wake count) (sleep-counter)])
  (define work (make-temporary-file "rivet-verify-~a" 'directory))
  (define exit-code
    (run-verify-remote-command
     (list "--repo" "acme/demo" "--ref" "main"
           "--output-directory" (path->string work))
     #:run-gh (make-fake-gh!
               #:runs-after (green-runs-json)
               #:artifacts-by-run (all-green-artifacts))
     #:sleep wake
     #:now (lambda () 0)))
  (check-equal? exit-code 0)
  (check-equal? (count) 0))

;; The same command in --json mode reports the runs and the matrix verdict.
(let ()
  (define work (make-temporary-file "rivet-verify-~a" 'directory))
  (define-values (exit-code output)
    (capture-output
     (lambda ()
       (run-verify-remote-command
        (list "--repo" "acme/demo" "--ref" "main" "--json"
              "--output-directory" (path->string work))
        #:run-gh (make-fake-gh!
                  #:runs-after (green-runs-json)
                  #:artifacts-by-run (all-green-artifacts))
        #:sleep (lambda (_) (void))
        #:now (lambda () 0)))))
  (check-equal? exit-code 0)
  (define parsed (read-json (open-input-string output)))
  (check-equal? (hash-ref parsed 'repo) "acme/demo")
  (check-equal? (hash-ref parsed 'sha) sha-under-test)
  (check-equal? (length (hash-ref parsed 'runs)) 3)
  (check-equal? (hash-ref (hash-ref parsed 'matrix) 'status) "pass")
  (check-equal?
   (length (hash-ref (hash-ref parsed 'matrix) 'cells)) 3))

;; A red run still hands over its archived evidence; the failing platform's
;; report fails its matrix cell and the command exits 1.
(let ()
  (define work (make-temporary-file "rivet-verify-~a" 'directory))
  (define artifacts
    (hash 101 (list (cons "linux" (report-text "linux" "fail")))
          102 (list (cons "macos" (report-text "macos" "pass")))
          103 (list (cons "windows" (report-text "windows" "pass")))))
  (define-values (exit-code output)
    (capture-output
     (lambda ()
       (run-verify-remote-command
        (list "--repo" "acme/demo" "--ref" "main"
              "--output-directory" (path->string work))
        #:run-gh (make-fake-gh!
                  #:runs-after (green-runs-json)
                  #:watch-codes (hash 101 1)
                  #:artifacts-by-run artifacts)
        #:sleep (lambda (_) (void))
        #:now (lambda () 0)))))
  (check-equal? exit-code 1)
  (check-true (string-contains? output "FAIL")))

;; A leg that archives nothing leaves its platform uncovered; the matrix can
;; stay green for what it saw but the command still fails the verification.
(let ()
  (define work (make-temporary-file "rivet-verify-~a" 'directory))
  (define-values (exit-code output)
    (capture-output
     (lambda ()
       (run-verify-remote-command
        (list "--repo" "acme/demo" "--ref" "main" "--platform" "linux"
              "--output-directory" (path->string work))
        #:run-gh (make-fake-gh!
                  #:runs-after (jsexpr->string
                                (list (hasheq 'databaseId 101
                                              'headSha sha-under-test)))
                  #:artifacts-by-run (hash))
        #:sleep (lambda (_) (void))
        #:now (lambda () 0)))))
  (check-equal? exit-code 1)
  (check-true (string-contains? output "missing platform legs: linux"))
  (check-true (string-contains? output "run 101: no acceptance artifacts")))

;; The dispatcher waits across poll cycles before the runs appear. The
;; report only requires the linux leg, so a single green leg passes.
(let-values ([(wake count) (sleep-counter)])
  (define work (make-temporary-file "rivet-verify-~a" 'directory))
  (define exit-code
    (run-verify-remote-command
     (list "--repo" "acme/demo" "--ref" "main" "--platform" "linux"
           "--output-directory" (path->string work))
     #:run-gh (make-fake-gh!
               #:runs-after (jsexpr->string
                             (list (hasheq 'databaseId 101
                                           'headSha sha-under-test)))
               #:runs-after-on-call 4
               #:artifacts-by-run
               (hash 101 (list (cons "linux"
                                     (report-text "linux" "pass"
                                                  (list "linux"))))))
     #:sleep wake
     #:now (lambda () 0)))
  (check-equal? exit-code 0)
  (check-true (>= (count) 1)))

;; Runs that never appear fail loudly instead of blocking forever. The
;; injected clock advances past the timeout on its second reading.
(let ([tick 0])
  (check-exn
   #rx"dispatched verification runs never appeared"
   (lambda ()
     (run-verify-remote-command
      (list "--repo" "acme/demo" "--ref" "main")
      #:run-gh (make-fake-gh!)
      #:sleep (lambda (_) (void))
      #:now (lambda ()
              (set! tick (+ tick 100000))
              tick)))))

;; A workflow without a dispatch trigger fails the dispatch step.
(check-exn
 #rx"workflow dispatch failed"
 (lambda ()
   (run-verify-remote-command
    (list "--repo" "acme/demo" "--ref" "main")
    #:run-gh (make-fake-gh! #:dispatch-code 1)
    #:sleep (lambda (_) (void))
    #:now (lambda () 0))))

;; Argument validation stays fail-closed.
(check-exn #rx"missing required --repo"
           (lambda ()
             (run-verify-remote-command
              (list "--ref" "main")
              #:run-gh (make-fake-gh!)
              #:now (lambda () 0))))
(check-exn #rx"invalid --repo"
           (lambda ()
             (run-verify-remote-command
              (list "--repo" "acme-demo" "--ref" "main")
              #:run-gh (make-fake-gh!)
              #:now (lambda () 0))))
(check-exn #rx"unknown --platform"
           (lambda ()
             (run-verify-remote-command
              (list "--repo" "acme/demo" "--ref" "main"
                    "--platform" "freebsd")
              #:run-gh (make-fake-gh!)
              #:now (lambda () 0))))
