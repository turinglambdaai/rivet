#lang racket/base

;; Public CLI facade for the read-only stdlib scanner. Keep Python internals
;; in the Rivet package, not in each generated application's .github directory.
(require json
         racket/match
         racket/runtime-path
         racket/system)

(provide run-apple-review-command
         parse-apple-review-options)

(define-runtime-path scanner "apple-review-preflight.py")

(define (parse-apple-review-options args)
  (let loop ([rest args] [channel #f] [app #f] [json? #f])
    (match rest
      ['()
       (unless (and channel app)
         (raise-arguments-error 'rivet-apple-review
                                "both --channel and --app are required"
                                "arguments" args))
       (unless (member channel '("developer-id" "mac-app-store" "ios-app-store"))
         (raise-arguments-error 'rivet-apple-review
                                "unknown Apple release channel"
                                "channel" channel))
       (values channel app json?)]
      [(list* "--channel" value tail)
       (when channel (error 'rivet-apple-review "duplicate --channel"))
       (loop tail value app json?)]
      [(list* "--app" value tail)
       (when app (error 'rivet-apple-review "duplicate --app"))
       (loop tail channel value json?)]
      [(cons "--json" tail)
       (when json? (error 'rivet-apple-review "duplicate --json"))
       (loop tail channel app #t)]
      [(cons unknown _)
       (raise-arguments-error 'rivet-apple-review
                              "unknown or incomplete option"
                              "option" unknown)])))

(define (run-apple-review-command args)
  (define-values (channel app json?) (parse-apple-review-options args))
  (define python (or (find-executable-path "python3")
                     (find-executable-path "python")))
  (cond
    [(not python)
     (define message
       "Python 3 is not installed; Apple bundle inspection could not run")
     (if json?
         (begin
           (write-json
            (hasheq 'schema "rivet.apple-review-preflight.v1"
                    'channel channel 'app app
                    'blockers '() 'warnings '() 'manual_review '()
                    'unverified (list (hasheq 'code "python3-unavailable"
                                             'message message))
                    'status "needs-evidence"))
           (newline))
         (eprintf "rivet: Apple preflight unavailable: ~a\n" message))
     2]
    [else
     (apply system*/exit-code
            python (path->string scanner)
            (append (list "--channel" channel "--app" app)
                    (if json? '("--json") '())))]))
