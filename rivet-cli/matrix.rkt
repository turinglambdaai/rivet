#lang racket/base

;; Cross-platform verification matrix (issue #287). Every platform leg already
;; emits a machine-readable `raco rivet acceptance --json` report; the matrix
;; folds those reports into one verdict so an agent editing on any OS can see
;; which required kind/platform cells are proven, failing, or missing. The
;; local operating system is an editing environment, not the boundary of
;; verification.

(require json
         racket/file
         racket/list
         racket/match
         racket/string
         "acceptance.rkt")

(provide load-acceptance-report
         matrix-report
         display-matrix
         run-matrix-command)

;; Report files are JSON, so every enum arrives as a string; normalize at the
;; load boundary so aggregation, ordering, and cell lookup work on symbols.
(define (kind-symbol path value)
  (or (for/or ([kind (in-list acceptance-kinds)])
        (and (string=? value (symbol->string kind)) kind))
      (report-argument-error "acceptance report has an invalid member"
                             "path" path
                             "member" 'kind
                             "expected" (format "one of ~a" acceptance-kinds)
                             "value" value)))

(define (platform-symbol path value)
  (or (for/or ([platform (in-list supported-platforms)])
        (and (string=? value (symbol->string platform)) platform))
      (report-argument-error "acceptance report has an invalid member"
                             "path" path
                             "member" 'platform
                             "expected" "windows, macos, or linux"
                             "value" value)))

(define (platform-list path value)
  (unless (and (list? value)
               (pair? value)
               (andmap string? value))
    (report-argument-error "acceptance report has an invalid member"
                           "path" path
                           "member" 'platforms
                           "expected" "non-empty list of platform names"
                           "value" value))
  (map (lambda (item) (platform-symbol path item)) value))

(define (report-argument-error message . fields)
  (apply raise-arguments-error 'rivet-matrix message fields))

(define (json-member report path key predicate expected)
  (define item
    (hash-ref report key
              (lambda ()
                (report-argument-error
                 "acceptance report is missing a required member"
                 "path" path
                 "member" key))))
  (unless (predicate item)
    (report-argument-error
     "acceptance report has an invalid member"
     "path" path
     "member" key
     "expected" expected
     "value" item))
  item)

(define (report-requirement-pairs path requirement)
  (unless (hash? requirement)
    (report-argument-error "acceptance report requirement must be an object"
                           "path" path
                           "value" requirement))
  (define kind
    (kind-symbol path
                 (json-member requirement path 'kind string? "kind name string")))
  (define platforms
    (platform-list
     path
     (json-member requirement path 'platforms list?
                  "non-empty list of platform names")))
  (for/list ([platform (in-list platforms)]) (cons kind platform)))

;; A report is trusted only after its shape validates; an aggregation gate
;; that silently tolerates malformed evidence would reinterpret completion.
(define (load-acceptance-report path)
  (unless (file-exists? path)
    (report-argument-error "acceptance report file is missing" "path" path))
  (define raw
    (with-handlers
        ([exn:fail?
          (lambda (error)
            (report-argument-error
             "acceptance report is not valid JSON"
             "path" path
             "message" (exn-message error)))])
      (call-with-input-file path read-json)))
  (unless (hash? raw)
    (report-argument-error "acceptance report must be a JSON object"
                           "path" path))
  (json-member raw path 'format-version
               (lambda (value) (eqv? value 1))
               "1")
  (define project
    (json-member raw path 'project
                 (lambda (value) (and (string? value) (positive? (string-length value))))
                 "non-empty string"))
  (define platform
    (platform-symbol
     path
     (json-member raw path 'platform string? "platform name string")))
  (define selected-suite
    (json-member raw path 'selected-suite
                 (lambda (value) (or (string? value) (eq? value 'null)))
                 "suite id string or null"))
  (define raw-requirements
    (json-member raw path 'configured-requirements list? "list of objects"))
  (define raw-suites
    (json-member raw path 'suites
                 (lambda (value) (and (list? value) (pair? value)))
                 "non-empty list of objects"))
  (define suites
    (for/list ([suite (in-list raw-suites)])
      (unless (hash? suite)
        (report-argument-error "acceptance report suite must be an object"
                               "path" path))
      (hash 'id (json-member suite path 'id
                             (lambda (value)
                               (and (string? value) (positive? (string-length value))))
                             "non-empty string")
            'kind (kind-symbol path
                               (json-member suite path 'kind
                                            string? "kind name string"))
            'status (json-member suite path 'status
                                 (lambda (value) (or (string=? value "pass")
                                                     (string=? value "fail")))
                                 "\"pass\" or \"fail\""))))
  (hash 'path (if (path? path) (path->string path) path)
        'project project
        'platform platform
        'partial (not (eq? selected-suite 'null))
        'requirements
        (remove-duplicates
         (append*
          (for/list ([requirement (in-list raw-requirements)])
            (report-requirement-pairs path requirement))))
        'suites suites))

;; Cell rule: a required kind/platform pair is proven when at least one
;; supplied report for that platform shows a passing suite of that kind; any
;; ran-but-not-passed evidence fails the cell; nothing ran means missing.
;; Feeding the current commit's reports is the caller's curation duty, so the
;; rule stays deterministic instead of heuristically picking fresher runs.
(define (cell-status kind platform reports)
  (define relevant
    (append*
     (for/list ([report (in-list reports)]
                #:when (eq? platform (hash-ref report 'platform)))
       (for/list ([suite (in-list (hash-ref report 'suites))]
                  #:when (eq? kind (hash-ref suite 'kind)))
         (hash-ref suite 'status)))))
  (cond [(member "pass" relevant) "pass"]
        [(pair? relevant) "fail"]
        [else "missing"]))

;; Reports must describe one product: a matrix spanning projects would let a
;; green leg of one product vouch for another.
(define (matrix-report reports)
  (unless (pair? reports)
    (report-argument-error "matrix aggregation needs at least one report"))
  (define projects
    (remove-duplicates (map (lambda (report) (hash-ref report 'project)) reports)))
  (unless (= 1 (length projects))
    (report-argument-error "matrix reports must all describe the same project"
                           "projects" projects))
  (define kind-order
    (lambda (left right)
      (define left-kind (index-of acceptance-kinds (car left)))
      (define right-kind (index-of acceptance-kinds (car right)))
      (or (< left-kind right-kind)
          (and (= left-kind right-kind)
               (< (index-of supported-platforms (cdr left))
                  (index-of supported-platforms (cdr right)))))))
  (define requirements
    (sort (remove-duplicates
           (append* (map (lambda (report) (hash-ref report 'requirements)) reports)))
          kind-order))
  (define cells
    (for/list ([requirement (in-list requirements)])
      (hash 'kind (symbol->string (car requirement))
            'platform (symbol->string (cdr requirement))
            'status (cell-status (car requirement) (cdr requirement) reports))))
  (hash 'format-version 1
        'project (first projects)
        'reports (for/list ([report (in-list reports)])
                   (hash 'path (hash-ref report 'path)
                         'platform (symbol->string (hash-ref report 'platform))
                         'partial (hash-ref report 'partial)
                         'status (if (for/and ([suite (in-list (hash-ref report 'suites))])
                                       (string=? (hash-ref suite 'status) "pass"))
                                     "pass"
                                     "fail")))
        'cells cells
        'status (if (andmap (lambda (cell) (string=? (hash-ref cell 'status) "pass"))
                            cells)
                    "pass"
                    "fail")))

(define (string-pad-right text width)
  (if (>= (string-length text) width)
      text
      (string-append text (make-string (- width (string-length text)) #\space))))

(define (string-pad-left text width)
  (if (>= (string-length text) width)
      text
      (string-append (make-string (- width (string-length text)) #\space) text)))

(define (cell-text status)
  (case status [("pass") "PASS"] [("fail") "FAIL"] [else "-"]))

(define (display-matrix matrix)
  (define kinds
    (remove-duplicates (map (lambda (cell) (hash-ref cell 'kind))
                            (hash-ref matrix 'cells))))
  (define platforms (map symbol->string supported-platforms))
  (define cell-map
    (for/hash ([cell (in-list (hash-ref matrix 'cells))])
      (values (cons (hash-ref cell 'kind) (hash-ref cell 'platform))
              (hash-ref cell 'status))))
  (define kind-width
    (for/fold ([width (string-length "requirement")])
              ([kind (in-list kinds)])
      (max width (string-length kind))))
  (define report-count (length (hash-ref matrix 'reports)))
  (printf "Rivet verification matrix: ~a - ~a report~a\n"
          (hash-ref matrix 'project) report-count
          (if (= report-count 1) "" "s"))
  (newline)
  (printf "  ~a" (string-pad-right "requirement" kind-width))
  (for ([platform (in-list platforms)])
    (printf "  ~a" (string-pad-left platform 8)))
  (newline)
  (for ([kind (in-list kinds)])
    (printf "  ~a" (string-pad-right kind kind-width))
    (for ([platform (in-list platforms)])
      (printf "  ~a"
              (string-pad-left
               (cell-text (hash-ref cell-map (cons kind platform) "missing")) 8)))
    (newline))
  (newline)
  (for ([report (in-list (hash-ref matrix 'reports))])
    (printf "  ~a  ~a~a  ~a\n"
            (string-pad-left (hash-ref report 'platform) 8)
            (string-pad-left (hash-ref report 'status) 4)
            (if (hash-ref report 'partial)
                "  (partial: --suite run)"
                (make-string 24 #\space))
            (hash-ref report 'path)))
  (newline)
  (printf "Cross-platform status: ~a\n" (string-upcase (hash-ref matrix 'status))))

(define (parse-arguments args)
  (let loop ([remaining args]
             [json? #f]
             [reports '()])
    (match remaining
      ['()
       (unless (pair? reports)
         (raise-arguments-error
          'rivet-matrix
          "expected at least one acceptance report path"
          "usage" "raco rivet matrix <report.json>... [--json]"))
       (values json? (reverse reports))]
      [(cons "--json" tail)
       (when json?
         (raise-arguments-error 'rivet-matrix "duplicate --json option"))
       (loop tail #t reports)]
      [(cons path tail)
       (loop tail json? (cons path reports))]
      [_
       (raise-arguments-error
        'rivet-matrix
        "expected <report.json>... [--json]"
        "arguments" args)])))

(define (run-matrix-command args)
  (define-values (json? paths) (parse-arguments args))
  (define reports (map load-acceptance-report paths))
  (define matrix (matrix-report reports))
  (if json?
      (begin
        (write-json matrix)
        (newline))
      (display-matrix matrix))
  (if (string=? (hash-ref matrix 'status) "pass") 0 1))
