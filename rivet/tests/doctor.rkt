#lang racket/base

(require json
         racket/file
         racket/port
         rackunit
         "../../rivet-cli/codegen.rkt"
         "../../rivet-cli/doctor.rkt"
         "../../rivet-cli/project.rkt"
         "../../rivet-cli/scaffold.rkt")

(define report (doctor-report))

(check-true (hash? report))
(for ([key (in-list '(os
                      architecture
                      supported
                      usable
                      ui
                      racket-executable
                      raco
                      racket-version
                      runtime
                      runtime-error
                      project-readiness
                      warnings
                      tools))])
  (check-true (hash-has-key? report key)))

(check-true (string? (hash-ref report 'os)))
(check-true (string? (hash-ref report 'architecture)))
(check-true (boolean? (hash-ref report 'supported)))
(check-true (boolean? (hash-ref report 'usable)))
(check-true (string? (hash-ref report 'racket-version)))
(check-true (hash? (hash-ref report 'tools)))
(check-true (list? (hash-ref report 'warnings)))
(check-true (list? (doctor-remediations report)))

;; Keep remediation logic deterministic and useful even when this test runs on
;; a machine whose real developer toolchain is complete.
(define incomplete-windows
  (hash 'os "windows"
        'supported #t
        'usable #f
        'racket-executable "C:\\Racket\\racket.exe"
        'raco "C:\\Racket\\raco.exe"
        'runtime (hash)
        'runtime-error #f
        'tools (hash 'msbuild #f
                     'cl #f
                     'lib #f
                     'dumpbin #f
                     'signtool #f)))
(define windows-fixes (doctor-remediations incomplete-windows))
(check-true
 (for/or ([fix (in-list windows-fixes)])
   (regexp-match? #rx"Windows C\\+\\+ toolchain" (car fix))))

(define incomplete-macos
  (hash 'os "macosx"
        'supported #t
        'usable #f
        'racket-executable "/Applications/Racket/bin/racket"
        'raco "/Applications/Racket/bin/raco"
        'runtime (hash)
        'runtime-error #f
        'tools (hash 'swift #f
                     'xcodebuild #f
                     'otool #f
                     'codesign #f
                     'plutil #f
                     'xcrun #f
                     'spctl #f)))
(define mac-fixes (doctor-remediations incomplete-macos))
(check-true
 (for/or ([fix (in-list mac-fixes)])
   (regexp-match? #rx"Apple developer toolchain" (car fix))))

(define incomplete-linux
  (hash 'os "unix"
        'supported #t
        'usable #f
        'racket-executable "/usr/bin/racket"
        'raco "/usr/bin/raco"
        'runtime (hash)
        'runtime-error #f
        'tools (hash 'cmake #f
                     'pkg-config #f
                     'c++ #f
                     'ldd #f
                     'gtk4 #f)))
(define linux-fixes (doctor-remediations incomplete-linux))
(check-true
 (for/or ([fix (in-list linux-fixes)])
   (regexp-match? #rx"Linux native toolchain" (car fix))))

;; The Racket executable can be present while its separate native-embedding
;; runtime is missing. The remedy must not recommend a *full* distribution
;; as the fix for missing boot files / static libraries (issue #365).
(define unavailable-embedding
  (hash-set (hash-set incomplete-linux 'runtime #f)
            'runtime-error
            "missing: petite.boot, scheme.boot, and racket.boot"))
(define embedding-fixes (doctor-remediations unavailable-embedding))
(check-true
 (for/or ([fix (in-list embedding-fixes)])
   (and (regexp-match? #rx"minimal source-built Racket CS" (cdr fix))
        (regexp-match? #rx"RIVET_RACKET_BOOT_DIR" (cdr fix)))))
(check-false
 (for/or ([fix (in-list embedding-fixes)])
   (regexp-match? #rx"Install a full Racket CS distribution" (cdr fix))))

;; `doctor --json` is intended for CI and agents. Keep the report inside the
;; Racket JSON data model and verify it survives a complete encode/decode pass.
(define encoded
  (let ([out (open-output-string)])
    (write-json report out)
    (get-output-string out)))
(check-true (positive? (string-length encoded)))

(define decoded
  (call-with-input-string encoded read-json))
(check-equal? (hash-ref decoded 'os) (hash-ref report 'os))
(check-equal? (hash-ref decoded 'architecture) (hash-ref report 'architecture))
(check-equal? (hash-ref decoded 'supported) (hash-ref report 'supported))
(check-equal? (hash-ref decoded 'usable) (hash-ref report 'usable))
(check-equal? (hash-ref decoded 'racket-version) (hash-ref report 'racket-version))

;; ---- Release gate (issues #245 and #255) ----
;;
;; The gate is exercised against a real scaffolded project: fresh generated
;; files and honest update-API calls must pass; a hand-edited generated
;; file, a drifted keyword, and an empty pin ref must each fail with a
;; finding that names the cause.

(define (release-check-named report name)
  (for/first ([check (in-list (hash-ref report 'checks))]
              #:when (string=? (hash-ref check 'name) name))
    check))

(define (release-check-passed? report name)
  (define check (release-check-named report name))
  (check-true (and check (string=? (hash-ref check 'status) "pass"))
              (format "~a did not pass: ~a"
                      name (and check (hash-ref check 'detail)))))

(define (release-check-failed? report name expected-rx)
  (define check (release-check-named report name))
  (check-true (and check (string=? (hash-ref check 'status) "fail"))
              (format "~a did not fail" name))
  (when check
    (check-true (regexp-match? expected-rx (or (hash-ref check 'detail) ""))
                (format "~a failed with unexpected detail: ~a"
                        name (hash-ref check 'detail)))))

(define temp-gate-root (make-temporary-file "rivet-release-gate-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "gate" temp-gate-root))
    (define project (load-project project-root))
    ;; The baseline lives at the project root (what every downstream
    ;; commits); a cwd-relative path would drop it next to this test file
    ;; and stay behind after the run.
    (write-schema-snapshot! project
                            (build-path project-root "rivet-schema.json"))
    (generate-clients! project)
    ;; A stray good-shaped updater call and a workflow pin keep the green
    ;; path realistic: the scanner and pin check run on every report.
    (call-with-output-file
     (build-path project-root "updater-usage.rkt")
     #:exists 'truncate
     (lambda (out)
       (displayln #<<RKT
#lang racket/base
(require rivet/distribution)
(define (check manifest-url key)
  (fetch-update-manifest manifest-url key
                         #:key-id "gate-2026-10"
                         #:maximum-bytes 4096))
RKT
       out)))
    (define installed (installed-rivet-release-version))
    (when installed
      (make-directory* (build-path project-root ".github" "workflows"))
      (call-with-output-file
       (build-path project-root ".github" "workflows" "ci.yml")
       #:exists 'truncate
       (lambda (out)
         (displayln
          (format "packages: 'https://github.com/turlamai/rivet.git#v~a'"
                  installed)
          out))))

    (define green (release-doctor-report project))
    (check-equal? (hash-ref green 'failed) 0)
    (release-check-passed? green "generated clients are fresh")
    (release-check-passed? green "schema baseline exists and is compatible")
    (release-check-passed?
     green "host sources call the update API with accepted keywords")
    (release-check-passed?
     green "dependency pins are non-empty and match the installed release")

    ;; Red 1: hand-edited generated file (the taskly/fulcrum/syncpilot stamp
    ;; drift class). Doctor regenerates in memory, so a version-literal edit
    ;; cannot hide.
    (call-with-output-file
     (build-path project-root "windows" "GeneratedBackend.hpp")
     #:exists 'truncate
     (lambda (out) (display "// hand-edited stamp\n" out)))
    (define stale-report (release-doctor-report project))
    (release-check-failed? stale-report
                           "generated clients are fresh"
                           #rx"run `raco rivet generate`")

    ;; Red 2: the payback #:redirections class — a keyword the installed
    ;; rivet does not accept, caught against the live procedure contract.
    (call-with-output-file
     (build-path project-root "updater-usage.rkt")
     #:exists 'truncate
     (lambda (out)
       (displayln #<<RKT
#lang racket/base
(require rivet/distribution)
(define (check manifest-url key)
  (fetch-update-manifest manifest-url key #:redirections 10))
RKT
       out)))
    (define drift-report (release-doctor-report project))
    (release-check-failed? drift-report
                           "host sources call the update API with accepted keywords"
                           #rx"does not accept #:redirections")

    ;; Red 3: the autarx empty-ref incident.
    (when (directory-exists? (build-path project-root ".github" "workflows"))
      (call-with-output-file
       (build-path project-root ".github" "workflows" "ci.yml")
       #:exists 'truncate
       (lambda (out)
         (displayln
          "packages: 'https://github.com/turlamai/rivet.git#'"
          out)))
      (define empty-ref-report (release-doctor-report project))
      (release-check-failed? empty-ref-report
                             "dependency pins are non-empty and match the installed release"
                             #rx"empty ref"))

    ;; Issue #310: a variable-mediated pin is resolved against this file's
    ;; env block; an undefined variable and a resolved wrong tag both fail;
    ;; a past pin in changelog prose is history, not a live pin, while the
    ;; shape-based empty-ref check still applies to prose.
    (let ([workflows (build-path project-root ".github" "workflows")])
      (when (directory-exists? workflows)
        (define (write-ci content)
          (call-with-output-file
           (build-path workflows "ci.yml")
           #:exists 'truncate
           (lambda (out) (displayln content out))))
        ;; mediated and resolved to the installed release -> passes
        (write-ci
         (format "env:\n  RIVET_PIN: v~a\npackages: \"https://github.com/turlamai/rivet.git#${{ env.RIVET_PIN }}\""
                 installed))
        (define mediated-report (release-doctor-report project))
        (release-check-passed?
         mediated-report
         "dependency pins are non-empty and match the installed release")
        ;; mediated but undefined -> fails naming the variable
        (write-ci
         "packages: \"https://github.com/turlamai/rivet.git#${{ env.RIVET_PIN }}\"")
        (define unresolved-report (release-doctor-report project))
        (release-check-failed?
         unresolved-report
         "dependency pins are non-empty and match the installed release"
         #rx"reads an env variable this file does not define")
        ;; mediated and resolved to a wrong tag -> fails the comparison
        (write-ci
         "env:\n  RIVET_PIN: v0.0.1\npackages: \"https://github.com/turlamai/rivet.git#${{ env.RIVET_PIN }}\"")
        (define wrong-tag-report (release-doctor-report project))
        (release-check-failed?
         wrong-tag-report
         "dependency pins are non-empty and match the installed release"
         #rx"does not match the installed rivet release")
        ;; restore the live workflow to the installed release, then check
        ;; that changelog prose naming a past pin is exempt from the comparison
        (write-ci
         (format "env:\n  RIVET_PIN: v~a\npackages: \"https://github.com/turlamai/rivet.git#${{ env.RIVET_PIN }}\""
                 installed))
        (call-with-output-file
         (build-path project-root "CHANGELOG.md")
         #:exists 'truncate
         (lambda (out)
           (displayln "installed Rivet from `rivet.git#v0.0.1` instead of floating"
                      out)))
        (define history-report (release-doctor-report project))
        (release-check-passed?
         history-report
         "dependency pins are non-empty and match the installed release")
        ;; but an empty ref in prose is still the autarx shape
        (call-with-output-file
         (build-path project-root "CHANGELOG.md")
         #:exists 'truncate
         (lambda (out)
           (displayln "installed Rivet from `rivet.git#` instead of floating"
                      out)))
        (define prose-empty-report (release-doctor-report project))
        (release-check-failed?
         prose-empty-report
         "dependency pins are non-empty and match the installed release"
         #rx"empty ref")))

    ;; The scanner itself is exported so products can run just this check.
    ;; updater-usage.rkt still holds the red-2 drifted call here, so the
    ;; direct scan must report the violation against the live contract.
    (define direct-violations
      (update-api-contract-violations
       (hash 'fetch-update-manifest
             (dynamic-require 'rivet/distribution 'fetch-update-manifest))
       (build-path project-root "updater-usage.rkt")))
    (check-equal? (length direct-violations) 1)
    (check-true
     (regexp-match? #rx"does not accept #:redirections"
                    (car direct-violations))))
  (lambda ()
    (when (directory-exists? temp-gate-root)
      (delete-directory/files temp-gate-root))))
