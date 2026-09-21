#lang racket/base

(require racket/file
         racket/path
         rackunit
         (submod "../rivet-cli/runtime.rkt" test-support))

(define temp-root (make-temporary-file "rivet-runtime-~a" 'directory))

(define (touch path)
  (make-directory* (path-only path))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display "fixture" out)))
  path)

(define (write-boot-set dir)
  (for ([name (in-list '("petite.boot" "scheme.boot" "racket.boot"))])
    (touch (build-path dir name))))

(dynamic-wind
  void
  (lambda ()
    ;; A complete boot set is selected as one unit from a single directory.
    ;; An incomplete earlier candidate must not be combined with a later one.
    (define incomplete (build-path temp-root "incomplete"))
    (touch (build-path incomplete "petite.boot"))
    (define complete (build-path temp-root "complete"))
    (write-boot-set complete)
    (define boots (find-complete-boot-files (list incomplete complete)))
    (check-equal? (map file-name-from-path boots)
                  (map string->path '("petite.boot" "scheme.boot" "racket.boot")))
    (for ([path (in-list boots)])
      (check-equal? (simplify-path (path-only path) #t)
                    (simplify-path complete #t)))

    ;; Runtime discovery is deliberately non-recursive. A matching artifact in
    ;; a nested directory is invisible unless that directory is an explicit
    ;; bounded candidate.
    (define direct-root (build-path temp-root "direct-root"))
    (define nested (build-path direct-root "nested"))
    (write-boot-set nested)
    (check-false (find-complete-boot-files (list direct-root)))
    (check-not-false (find-complete-boot-files (list nested)))

    (define dll-root (build-path temp-root "dll-root"))
    (define nested-dll-root (build-path dll-root "nested"))
    (make-directory* nested-dll-root)
    (touch (build-path nested-dll-root "libracketcs_nested.dll"))
    (check-false
     (find-direct-matching-file
      (list dll-root)
      #px"(?i:^libracketcs.*\\.dll$)"))
    (define direct-dll (touch (build-path dll-root "libracketcs_direct.dll")))
    (check-equal?
     (find-direct-matching-file
      (list dll-root)
      #px"(?i:^libracketcs.*\\.dll$)")
     (simplify-path direct-dll #t))

    ;; macOS framework discovery enumerates only immediate Versions entries and
    ;; then checks each known boot directory directly.
    (define framework (build-path temp-root "Racket.framework"))
    (define framework-boot
      (build-path framework "Versions" "9.3_CS" "boot"))
    (write-boot-set framework-boot)
    (define framework-dirs (framework-boot-directories framework))
    (check-not-false
     (member (simplify-path framework-boot #t) framework-dirs equal?))
    (check-not-false (find-complete-boot-files framework-dirs)))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
