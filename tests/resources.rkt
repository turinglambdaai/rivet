#lang racket/base

(require rackunit
         racket/file
         racket/path
         (submod "../rivet-cli/build.rkt" test-support)
         (submod "../rivet-cli/package.rkt" test-support)
         "../rivet-cli/project.rkt"
         "../rivet/resources.rkt")

(define temp-root (make-temporary-file "rivet-resources-~a" 'directory))
(define external-root (make-temporary-file "rivet-resources-external-~a" 'directory))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display text out))))

(dynamic-wind
  void
  (lambda ()
    (define assets (build-path temp-root "assets"))
    (define settings (build-path temp-root "config" "defaults.json"))
    (write-text (build-path assets "images" "hero.txt") "hero")
    (make-directory* (build-path assets "empty"))
    (write-text settings "{}")
    (write-text (build-path temp-root "branding" "app.ico") "ico")

    (define project
      (rivet-project
       temp-root
       #hasheq((resources . ("assets" "config/defaults.json"))
               (windows-icon . "branding/app.ico"))))
    (define stage (build-path temp-root ".rivet" "stage"))
    (make-directory* stage)
    (copy-project-resources! project stage)

    (check-equal? (file->string (build-path stage "app" "assets" "images" "hero.txt"))
                  "hero")
    (check-true (directory-exists? (build-path stage "app" "assets" "empty")))
    (check-equal? (file->string (build-path stage "app" "config" "defaults.json"))
                  "{}")

    (parameterize ([current-resource-root (build-path stage "app")])
      (check-equal? (file->string (resource-path "assets" "images" "hero.txt"))
                    "hero")
      (check-exn exn:fail? (lambda () (resource-path ".." "secret")))
      (check-exn exn:fail? (lambda () (resource-path "assets/../secret"))))

    (define rc (prepare-windows-icon-resource! project))
    (check-true (file-exists? rc))
    (check-true
     (regexp-match? #rx"IDI_RIVET_APP_ICON ICON"
                    (file->string rc)))
    (check-false (regexp-match? #rx"\\\\" (file->string rc)))

    (define plist (build-path temp-root "Info.plist"))
    (write-macos-info! plist
                       "Demo & Test"
                       "Demo"
                       "dev.rivet.demo"
                       "1.2.3"
                       7
                       "14.0"
                       "AppIcon.icns"
                       '("demo")
                       '())
    (define plist-text (file->string plist))
    (check-true
     (regexp-match? #rx"<key>CFBundleIconFile</key><string>AppIcon.icns</string>"
                    plist-text))
    (check-true (regexp-match? #rx"Demo &amp; Test" plist-text))

    (define missing-project
      (rivet-project temp-root #hasheq((resources . ("missing.txt")))))
    (check-exn #rx"does not exist"
               (lambda ()
                 (copy-project-resources! missing-project
                                          (build-path temp-root "missing-stage"))))

    (define external-file (build-path external-root "outside.txt"))
    (write-text external-file "outside")
    (define linked (build-path temp-root "linked.txt"))
    (make-file-or-directory-link external-file linked)
    (define linked-project
      (rivet-project temp-root #hasheq((resources . ("linked.txt")))))
    (check-exn #rx"symbolic links or junctions"
               (lambda ()
                 (copy-project-resources! linked-project
                                          (build-path temp-root "linked-stage")))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))
    (when (directory-exists? external-root)
      (delete-directory/files external-root))))
