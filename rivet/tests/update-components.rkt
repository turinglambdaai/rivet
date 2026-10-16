#lang racket/base

;; The manifest component discriminator (#248) and the release
;; --update-payload expansion (#244): legacy manifests keep working, a
;; component-bearing feed selects by component, and payload specs expand
;; globs into component-tagged artifacts.

(require rackunit
         racket/file
         racket/path
         racket/string
         "../../rivet/distribution/manifest.rkt"
         "../../rivet/distribution/updater.rkt"
         "../../rivet-cli/project.rkt"
         (rename-in (submod "../../rivet-cli/release.rkt" test-support)
                    [parse-update-payload-spec parse-update-payload-spec/t]
                    [expand-update-payloads expand-update-payloads/t]))

;; --- legacy shape round-trips without component ----------------------------

(define legacy
  (update-manifest "dev.rivet.test" "1.2.0" 12 'stable
                   "2026-09-28T00:00:00Z" "1.0.0" "1.1.0"
                   #t 100
                   (list (update-artifact 'windows 'x64
                                          "https://updates.example/app.zip"
                                          (make-string 64 #\a)
                                          4 'zip '() #f))))
(define legacy-bytes (manifest->payload-bytes legacy))
(check-false (regexp-match? #"component" legacy-bytes))
(check-equal? (payload-bytes->manifest legacy-bytes) legacy)

;; --- component round-trips and validates ----------------------------------

(define component-manifest
  (update-manifest "dev.rivet.test" "1.2.0" 12 'stable
                   "2026-09-28T00:00:00Z" "1.0.0" "1.1.0"
                   #t 100
                   (list (update-artifact 'macos 'arm64
                                          "https://updates.example/app.zip"
                                          (make-string 64 #\b)
                                          4 'zip '() 'app)
                         (update-artifact 'macos 'arm64
                                          "https://updates.example/cli.zip"
                                          (make-string 64 #\c)
                                          4 'zip '() 'cli))))
(define component-bytes (manifest->payload-bytes component-manifest))
(check-true (regexp-match? #"\"component\":\"app\"" component-bytes))
(check-equal? (payload-bytes->manifest component-bytes) component-manifest)

;; Unsupported component names fail closed.
(check-exn #rx"artifact component is not supported"
           (lambda ()
             (payload-bytes->manifest
              (manifest->payload-bytes
               (update-manifest "dev.rivet.test" "1.2.0" 12 'stable
                                "2026-09-28T00:00:00Z" "1.0.0" "1.1.0"
                                #t 100
                                (list (update-artifact 'macos 'arm64
                                                       "https://updates.example/x.zip"
                                                       (make-string 64 #\d)
                                                       4 'zip '() 'bundle)))))))

;; --- selection by component ------------------------------------------------

(define config
  (updater-config "dev.rivet.test" "1.1.0" 'stable 'macos 'arm64
                  #f #f 0 (* 1024 1024) 'app))
(check-equal? (update-candidate-artifact
               (select-update config component-manifest))
              (update-artifact 'macos 'arm64
                               "https://updates.example/app.zip"
                               (make-string 64 #\b)
                               4 'zip '() 'app))
(check-equal?
 (update-candidate-artifact
  (select-update (struct-copy updater-config config [component 'cli])
                 component-manifest
                 #:install-kind 'portable))
 (update-artifact 'macos 'arm64
                  "https://updates.example/cli.zip"
                  (make-string 64 #\c)
                  4 'zip '() 'cli))
;; A legacy config without a component only matches component-less entries,
;; so this component-bearing feed has nothing for it.
(check-false (select-update (struct-copy updater-config config [component #f])
                            component-manifest))

;; --- payload spec parsing --------------------------------------------------

(check-exn #rx"--update-payload expects"
           (lambda () (parse-update-payload-spec/t 'test "zip")))
(check-exn #rx"update payload installer must be"
           (lambda () (parse-update-payload-spec/t 'test "tgz:dist/x.tar.gz")))
(check-exn #rx"update payload component must be"
           (lambda () (parse-update-payload-spec/t 'test "zip:dist/x.zip:bundle")))

;; --- glob expansion --------------------------------------------------------

(define root (make-temporary-file "rivet-update-payloads-~a" 'directory))
(define project
  (rivet-project root (hasheq 'name "Payload" 'version "1.0.0")))
(define dist (build-path root "dist"))
(make-directory* dist)
(call-with-output-file (build-path dist "Payload-tool-linux-x64.tar.gz")
  (lambda (out) (write-bytes (make-bytes 32 5) out)))
(call-with-output-file (build-path dist "Payload-tool-linux-arm64.tar.gz")
  (lambda (out) (write-bytes (make-bytes 32 6) out)))

(define update-config
  (update-environment "https://updates.example/payload/"
                      (make-bytes 32 1)
                      "release-2026"))
(define expanded
  (expand-update-payloads/t update-config project 'linux 'x64
                                (list "zip:dist/*-linux-x64.tar.gz:tool")))
(check-equal? (length expanded) 1)
(define expanded-artifact (car expanded))
(check-equal? (update-artifact-component expanded-artifact) 'tool)
(check-equal? (update-artifact-installer expanded-artifact) 'zip)
(check-true
 (string-suffix? (update-artifact-url expanded-artifact)
                 "Payload-tool-linux-x64.tar.gz"))
(check-equal? (update-artifact-size expanded-artifact) 32)

(check-exn #rx"matched no files"
           (lambda ()
             (expand-update-payloads/t update-config project 'linux 'x64
                                          (list "zip:dist/*-nope.tar.gz:tool"))))

(delete-directory/files root)
