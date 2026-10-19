#lang racket/base

(require racket/file
         racket/list
         rackunit
         "../../rivet-cli/acceptance.rkt"
         "../../rivet-cli/project.rkt"
         "../../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-acceptance-test-~a" 'directory))

(define (write-manifest root text)
  (call-with-output-file (build-path root default-acceptance-manifest-name)
    #:exists 'truncate/replace
    (lambda (output) (display text output))))

(define (result suite status)
  (hash 'id (symbol->string (acceptance-suite-id suite))
        'kind (symbol->string (acceptance-suite-kind suite))
        'status status
        'duration-ms 1
        'exit-code (if (string=? status "pass") 0 1)
        'timed-out #f
        'stdout ""
        'stderr ""
        'stdout-truncated #f
        'stderr-truncated #f
        'missing-evidence '()))

(dynamic-wind
 void
 (lambda ()
   (define root (create-project! "AcceptanceDemo" temp-root))
   (define project (load-project root))

   ;; The scaffold starts with explicit cross-platform contract/build
   ;; requirements. New products cannot silently claim an empty green run.
   (define-values (path starter-suites starter-requirements)
     (load-acceptance-manifest project))
   (check-true (file-exists? path))
   (check-equal? (map acceptance-suite-id starter-suites)
                 '(schema-contract native-build))
   (check-equal? (map car starter-requirements)
                 '(contract native-build))

   ;; A product can declare native commands per platform without introducing
   ;; a shared selector DSL. The orchestrator runs only the current leg.
   (write-manifest
    root
    #<<RKT
#hasheq(
 (version . 1)
 (requirements
  . (#hasheq((kind . contract) (platforms . (windows linux)))
     #hasheq((kind . native-ui) (platforms . (windows linux)))))
 (suites
  . (#hasheq((id . core)
             (kind . contract)
             (platforms . (windows linux))
             (command . ("raco" "test" "tests/")))
     #hasheq((id . windows-ui)
             (kind . native-ui)
             (platforms . (windows))
             (command . ("pwsh" "-File" "scripts/e2e/windows.ps1"))
             (evidence . (".rivet/acceptance/windows/trace.json")))
     #hasheq((id . linux-ui)
             (kind . native-ui)
             (platforms . (linux))
             (command . ("python3" "scripts/e2e/linux.py"))
             (timeout-seconds . 60)
             (evidence . (".rivet/acceptance/linux/trace.json"))))))
RKT
    )
   (define called '())
   (define report
     (acceptance-report
      project
      #:platform 'linux
      #:runner
      (lambda (_project suite)
        (set! called (cons (acceptance-suite-id suite) called))
        (result suite "pass"))))
   (check-equal? (reverse called) '(core linux-ui))
   (check-equal? (hash-ref report 'status) "pass")
   (check-equal? (hash-ref report 'passed) 2)
   (check-equal? (hash-ref report 'failed) 0)

   ;; A failing runner remains a failing product report; orchestration does
   ;; not reinterpret or waive a suite result.
   (define red
     (acceptance-report
      project
      #:platform 'windows
      #:suite 'windows-ui
      #:runner (lambda (_project suite) (result suite "fail"))))
   (check-equal? (hash-ref red 'status) "fail")
   (check-equal? (hash-ref red 'failed) 1)

   ;; Declared requirements must be covered before any command starts.
   (write-manifest
    root
    #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . native-ui) (platforms . (macos)))))
 (suites
  . (#hasheq((id . core)
             (kind . contract)
             (platforms . (windows macos linux))
             (command . ("raco" "test" "tests/"))))))
RKT
    )
   (check-exn #rx"required acceptance coverage has no suite"
              (lambda () (load-acceptance-manifest project)))

   ;; Evidence is disposable run output. It cannot escape Rivet's generated
   ;; acceptance root, where the orchestrator can safely remove stale files.
   (write-manifest
    root
    #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . contract) (platforms . (linux)))))
 (suites
  . (#hasheq((id . core)
             (kind . contract)
             (platforms . (linux))
             (command . ("raco" "test" "tests/"))
             (evidence . ("artifacts/outside.txt"))))))
RKT
    )
   (check-exn #rx"invalid suite evidence"
               (lambda () (load-acceptance-manifest project)))

   ;; Native UI, package, and release claims require a durable artifact from
   ;; this run; a zero-exit stub alone is not acceptance evidence.
   (write-manifest
    root
    #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . native-ui) (platforms . (linux)))))
 (suites
  . (#hasheq((id . no-ui-proof)
             (kind . native-ui)
             (platforms . (linux))
             (command . ("racket" "-e" "(void)"))))))
RKT
    )
   (check-exn #rx"suite kind requires at least one evidence file"
              (lambda () (load-acceptance-manifest project)))

   ;; A stale file cannot make a suite green. Rivet removes declared output
   ;; before launching the command and requires this run to recreate it.
   (write-manifest
    root
    #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . contract) (platforms . (windows)))))
 (suites
  . (#hasheq((id . stale-proof)
             (kind . contract)
             (platforms . (windows))
             (command . ("racket" "-e" "(void)"))
             (evidence . (".rivet/acceptance/stale.txt"))))))
RKT
    )
   (define evidence-directory (build-path root ".rivet" "acceptance"))
   (make-directory* evidence-directory)
   (define stale-evidence (build-path evidence-directory "stale.txt"))
   (call-with-output-file stale-evidence
     #:exists 'truncate/replace
     (lambda (output) (display "old run" output)))
   (define stale-report
     (acceptance-report project #:platform 'windows))
   (check-equal? (hash-ref stale-report 'status) "fail")
   (check-equal?
    (hash-ref (first (hash-ref stale-report 'suites)) 'missing-evidence)
    '(".rivet/acceptance/stale.txt"))
   (check-false (file-exists? stale-evidence))

   ;; Evidence is classified (issue #287): accessibility snapshots are the
   ;; primary cross-platform record, screenshots are supplemental, and plain
   ;; string paths stay legal as the generic kind.
   (write-manifest
    root
    #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . native-ui) (platforms . (windows)))))
 (suites
  . (#hasheq((id . windows-ui)
             (kind . native-ui)
             (platforms . (windows))
             (command . ("pwsh" "-File" "scripts/ui.ps1"))
             (evidence
              . (#hasheq((path . ".rivet/acceptance/windows/ax.json")
                         (kind . accessibility-snapshot))
                 #hasheq((path . ".rivet/acceptance/windows/screen.png")
                         (kind . screenshot))
                 ".rivet/acceptance/windows/trace.json"))))))
RKT
    )
   (define-values (_classified-path classified-suites _classified-reqs)
     (load-acceptance-manifest project))
   (check-equal?
    (acceptance-suite-evidence (first classified-suites))
    '((".rivet/acceptance/windows/ax.json" . accessibility-snapshot)
      (".rivet/acceptance/windows/screen.png" . screenshot)
      (".rivet/acceptance/windows/trace.json" . generic)))

   ;; Unknown kinds and malformed entries are rejected before any suite runs.
   (for ([manifest-text (in-list
                         (list
                          #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . native-ui) (platforms . (windows)))))
 (suites
  . (#hasheq((id . windows-ui)
             (kind . native-ui)
             (platforms . (windows))
             (command . ("pwsh" "-File" "scripts/ui.ps1"))
             (evidence
              . (#hasheq((path . ".rivet/acceptance/windows/ax.json")
                         (kind . video))))))))
RKT
                          #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . native-ui) (platforms . (windows)))))
 (suites
  . (#hasheq((id . windows-ui)
             (kind . native-ui)
             (platforms . (windows))
             (command . ("pwsh" "-File" "scripts/ui.ps1"))
             (evidence
              . (#hasheq((kind . screenshot))))))))
RKT
                          #<<RKT
#hasheq(
 (version . 1)
 (requirements . (#hasheq((kind . native-ui) (platforms . (windows)))))
 (suites
  . (#hasheq((id . windows-ui)
             (kind . native-ui)
             (platforms . (windows))
             (command . ("pwsh" "-File" "scripts/ui.ps1"))
             (evidence
              . (#hasheq((path . ".rivet/acceptance/windows/ax.json")
                         (kind . screenshot)
                         (note . "extra"))))))))
RKT
                         ))])
     (write-manifest root manifest-text)
     (check-exn #rx"invalid suite evidence"
                (lambda () (load-acceptance-manifest project))))

   ;; The report pins each declared artifact's kind, presence, size, and
   ;; digest, so remote consumers audit what a green suite produced.
   (define classified-evidence-directory
     (build-path root ".rivet" "acceptance" "windows"))
   (make-directory* classified-evidence-directory)
   (call-with-output-file
    (build-path classified-evidence-directory "ax.json")
    #:exists 'truncate/replace
    (lambda (output) (display "{\"role\":\"window\"}" output)))
   (define recorded-suite
     (acceptance-suite 'windows-ui 'native-ui '(windows)
                       (list "pwsh" "-File" "scripts/ui.ps1") 900
                       '((".rivet/acceptance/windows/ax.json"
                          . accessibility-snapshot)
                         (".rivet/acceptance/windows/screen.png"
                          . screenshot))))
   (define entries (evidence-entries project recorded-suite))
   (check-equal? (length entries) 2)
   (define snapshot-entry (first entries))
   (check-equal? (hash-ref snapshot-entry 'kind) "accessibility-snapshot")
   (check-equal? (hash-ref snapshot-entry 'present) #t)
   (check-equal? (hash-ref snapshot-entry 'bytes)
                 (file-size (build-path classified-evidence-directory
                                        "ax.json")))
   (check-true (regexp-match? #px"^[0-9a-f]{64}$"
                              (hash-ref snapshot-entry 'sha256)))
   (define screenshot-entry (second entries))
   (check-equal? (hash-ref screenshot-entry 'kind) "screenshot")
   (check-equal? (hash-ref screenshot-entry 'present) #f)
   (check-equal? (hash-ref screenshot-entry 'sha256) 'null)
   (check-equal? (hash-ref screenshot-entry 'bytes) 'null))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
