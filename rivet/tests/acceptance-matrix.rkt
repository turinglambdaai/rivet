#lang racket/base

;; The cross-platform matrix is the aggregation gate over per-platform
;; acceptance reports: it may prove a cell only from a passing suite on that
;; platform's report, must fail closed on malformed evidence, and must never
;; let one product's green leg vouch for another.

(require json
         racket/file
         racket/list
         racket/port
         racket/runtime-path
         racket/string
         rackunit
         "../../rivet-cli/matrix.rkt")

(define temp-root (make-temporary-file "rivet-matrix-test-~a" 'directory))

(define (write-report! name content)
  (define path (build-path temp-root name))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (output) (display content output)))
  path)

(define (suite id kind status)
  (hash 'id id 'kind kind 'status status))

(define (report #:project [project "Taskly"]
                #:platform platform
                #:selected-suite [selected-suite 'null]
                #:requirements requirements
                #:suites suites)
  ;; A real report carries the whole manifest policy in
  ;; configured-requirements — every required kind with every platform it
  ;; must run on — not just the declaring leg's row.
  (hash 'format-version 1
        'project project
        'platform platform
        'manifest "rivet-acceptance.rktd"
        'configured-suites (length suites)
        'configured-requirements
        (for/list ([requirement (in-list requirements)])
          (hash 'kind (car requirement)
                'platforms (cdr requirement)))
        'selected-suite selected-suite
        'status (if (andmap (lambda (suite)
                              (string=? (hash-ref suite 'status) "pass"))
                            suites)
                    "pass"
                    "fail")
        'passed (count (lambda (suite) (string=? (hash-ref suite 'status) "pass"))
                       suites)
        'failed (- (length suites)
                   (count (lambda (suite)
                            (string=? (hash-ref suite 'status) "pass"))
                          suites))
        'suites suites))

;; JSON round trips symbols through strings; report files store strings.
(define (jsonify value)
  (define (stringify item)
    (cond [(symbol? item) (symbol->string item)]
          [(hash? item)
           (for/hash ([(key item) (in-hash item)])
             (values key (stringify item)))]
          [(list? item) (map stringify item)]
          [else item]))
  (with-output-to-string (lambda () (write-json (stringify value)))))

(define (file-report path-name report)
  (define path (write-report! path-name (jsonify report)))
  (load-acceptance-report path))

(dynamic-wind
 void
 (lambda ()
   ;; Full green evidence on every required platform proves the matrix.
   (define windows
     (file-report
      "windows.json"
      (report #:platform "windows"
              #:requirements '((contract windows linux) (native-ui windows linux))
              #:suites (list (suite "core" "contract" "pass")
                             (suite "windows-ui" "native-ui" "pass")))))
   (define linux
     (file-report
      "linux.json"
      (report #:platform "linux"
              #:requirements '((contract windows linux) (native-ui windows linux))
              #:suites (list (suite "core" "contract" "pass")
                             (suite "linux-ui" "native-ui" "fail")))))
   (define matrix (matrix-report (list windows linux)))
   (check-equal? (hash-ref matrix 'project) "Taskly")
   (check-equal? (hash-ref matrix 'status) "fail")
   (check-equal?
    (hash-ref matrix 'cells)
    (list (hash 'kind "contract" 'platform "windows" 'status "pass")
          (hash 'kind "contract" 'platform "linux" 'status "pass")
          (hash 'kind "native-ui" 'platform "windows" 'status "pass")
          (hash 'kind "native-ui" 'platform "linux" 'status "fail")))
   (check-equal? (length (hash-ref matrix 'reports)) 2)

   ;; A platform with no report is missing, never silently green.
   (define windows-only
     (matrix-report (list windows)))
   (check-equal? (hash-ref windows-only 'status) "fail")
   (check-true
    (pair? (member (hash 'kind "contract" 'platform "linux" 'status "missing")
                   (hash-ref windows-only 'cells)))
    "an unreported platform must be a missing cell")

   ;; A partial (--suite) run still contributes its own kind's evidence but is
   ;; flagged, so a gate reading the artifact sees the reduced scope.
   (define partial
     (file-report
      "partial.json"
      (report #:platform "macos"
              #:selected-suite "core"
              #:requirements '((contract macos))
              #:suites (list (suite "core" "contract" "pass")))))
   (check-true (hash-ref partial 'partial))
   (define partial-matrix (matrix-report (list partial)))
   (check-equal? (hash-ref partial-matrix 'cells)
                 (list (hash 'kind "contract" 'platform "macos" 'status "pass")))
   (check-true
     (hash-ref (first (hash-ref partial-matrix 'reports)) 'partial))

   ;; Malformed evidence fails closed instead of aggregating silently.
   (for ([text (in-list
                '("not json"
                  "[]"
                  "{\"format-version\": 2, \"project\": \"Taskly\"}"
                  "{\"format-version\": 1, \"project\": \"Taskly\"}"))])
     (define path (write-report! "broken.json" text))
     (check-exn #rx"acceptance report"
                (lambda () (load-acceptance-report path))
                (format "malformed report must be rejected: ~a" text)))
   (check-exn #rx"acceptance report file is missing"
              (lambda () (load-acceptance-report
                          (build-path temp-root "absent.json"))))

   ;; One product per matrix: a green leg of another product cannot vouch.
   (define other
     (file-report
      "other.json"
      (report #:project "Other"
              #:platform "macos"
              #:requirements '((contract macos))
              #:suites (list (suite "core" "contract" "pass")))))
   (check-exn #rx"same project"
              (lambda () (matrix-report (list windows other))))

   ;; The command exit code follows the matrix verdict and --json emits it.
   (define exit-code
     (parameterize ([current-output-port (open-output-nowhere)])
       (run-matrix-command
        (list (path->string (build-path temp-root "windows.json"))
              (path->string (build-path temp-root "linux.json"))))))
   (check-equal? exit-code 1)
   (define json-output (open-output-string))
   (define json-exit-code
     (parameterize ([current-output-port json-output])
       (run-matrix-command
        (list "--json"
              (path->string (build-path temp-root "partial.json"))))))
   (check-equal? json-exit-code 0)
   (define parsed (read-json (open-input-string (get-output-string json-output))))
   (check-equal? (hash-ref parsed 'status) "pass")
   (check-equal? (hash-ref parsed 'project) "Taskly")

   ;; Argument errors: no reports, unknown options.
   (check-exn #rx"at least one acceptance report"
              (lambda () (run-matrix-command '())))
   (check-exn #rx"duplicate --json"
              (lambda () (run-matrix-command
                          (list "--json" "--json" "report.json")))))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
