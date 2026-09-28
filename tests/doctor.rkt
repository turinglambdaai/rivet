#lang racket/base

(require json
         racket/port
         rackunit
         "../rivet-cli/doctor.rkt")

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
                      tools))])
  (check-true (hash-has-key? report key)))

(check-true (string? (hash-ref report 'os)))
(check-true (string? (hash-ref report 'architecture)))
(check-true (boolean? (hash-ref report 'supported)))
(check-true (boolean? (hash-ref report 'usable)))
(check-true (string? (hash-ref report 'racket-version)))
(check-true (hash? (hash-ref report 'tools)))
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
