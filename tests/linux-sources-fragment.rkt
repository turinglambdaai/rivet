#lang racket/base

;; The Linux platform source fragment is the library's private single source
;; of truth; hand-copied downstream lists are exactly what died on
;; global_shortcuts.cpp and clipboard.cpp. Guards:
;;
;;   1. every source path the fragment lists exists in the package — a
;;      rename or deletion must update the fragment in the same commit;
;;   2. the canonical host template consumes the fragment instead of
;;      carrying its own copy of the list — a second list is how the drift
;;      starts.

(require rackunit
         racket/file
         racket/path
         racket/string
         (for-syntax racket/base)
         racket/runtime-path)

;; tests/ sits directly under the package root
(define-runtime-path repository-root-reference "..")
(define package-root (simplify-path repository-root-reference))

(module+ test
  (define fragment-path
    (build-path package-root "platform" "linux" "rivet_linux_sources.cmake"))

  (test-case "the fragment exists at the documented location"
    (check-true (file-exists? fragment-path)))

  (define fragment (file->string fragment-path))

  (test-case "every source the fragment lists exists in the package"
    ;; only translation units count as listed sources; the usage comment
    ;; names the fragment itself through the same ${RIVET_ROOT} spelling
    (define referenced
      (for/list ([m (in-list (regexp-match* #px"\\$\\{RIVET_ROOT\\}/[^\"]+\\.cpp"
                                            fragment))]
                 #:when #t)
        (cadr (regexp-match #px"\\$\\{RIVET_ROOT\\}/(.*)" m))))
    (check-true (>= (length referenced) 10)
                "the fragment should list the full platform surface")
    (for ([rel (in-list referenced)])
      (check-true (file-exists? (build-path package-root rel))
                  (format "fragment lists a missing file: ~a" rel))))

  (test-case "the platform library consumes the fragment; hosts link the target"
    (define lib-cmake
      (file->string
       (build-path package-root "platform" "linux" "CMakeLists.txt")))
    (define host-cmake
      (file->string
       (build-path package-root "platform" "linux" "host" "CMakeLists.txt")))
    (check-true
     (string-contains? lib-cmake "rivet_linux_sources.cmake")
     "the platform library must include() the fragment")
    (check-true
     (regexp-match? #rx"add_library[(]rivet_platform" lib-cmake)
     "the platform library defines the target")
    (check-true
     (regexp-match? #rx"rivet::platform" host-cmake)
     "the host template links the library target")
    (check-false
     (regexp-match? #px"\\$\\{RIVET_ROOT\\}/platform/linux/system/[a-z_]+\\.cpp"
                    host-cmake)
     "the host template must not carry its own copy of the source list")
    (check-true
     (string-contains? fragment "not a downstream integration surface")
     "the internal fragment must not invite downstream source compilation")))
