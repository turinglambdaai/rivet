#lang racket/base

(require rackunit
         racket/file
         racket/path
         (submod "../../rivet-cli/build.rkt" test-support)
         (submod "../../rivet-cli/package.rkt" test-support)
         (submod "../../rivet-cli/verify.rkt" test-support)
         "../../rivet-cli/project.rkt"
         "../../rivet/app-info.rkt"
         "../../rivet/resources.rkt")

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
       #hasheq((name . "Demo_App")
               (resources . ("assets" "config/defaults.json"))
               (windows-icon . "branding/app.ico"))))
    (define stage (build-path temp-root ".rivet" "stage"))
    (make-directory* stage)
    (copy-project-resources! project stage)
    (write-app-info! project stage)

    (check-equal? (file->string (build-path stage "app" "assets" "images" "hero.txt"))
                  "hero")
    (check-true (directory-exists? (build-path stage "app" "assets" "empty")))
    (check-equal? (file->string (build-path stage "app" "config" "defaults.json"))
                  "{}")

    (parameterize ([current-resource-root (build-path stage "app")])
      (check-equal? (file->string (resource-path "assets" "images" "hero.txt"))
                    "hero")
      (check-equal? (app-name) "Demo_App")
      (check-equal? (app-display-name) "Demo_App")
      (check-equal? (app-version) "0.1.0")
      (check-equal? (app-build) 1)
      (check-equal? (app-identifier) "dev.rivet.demo-app")
      (check-equal? (app-release-channel) 'stable)
      (check-exn exn:fail? (lambda () (resource-path ".." "secret")))
      (check-exn exn:fail? (lambda () (resource-path "assets/../secret"))))

    (define metadata-path (build-path stage "app" "rivet-app-info.rktd"))
    (verify-configured-resources! 'test project stage)
    (check-exn #rx"reserved metadata path"
               (lambda () (write-app-info! project stage)))
    (write-text metadata-path "#hasheq((name . \"broken\"))\n")
    (parameterize ([current-resource-root (build-path stage "app")])
      (check-exn #rx"missing a required field" current-app-info))
    (check-exn #rx"does not match rivet.rktd"
               (lambda () (verify-configured-resources! 'test project stage)))

    (check-true (windows-release-excluded? (string->path "x64/RivetHost.pdb")))
    (check-true (windows-release-excluded? (string->path "x64/onnxruntime.dll")))
    (check-true (windows-release-excluded? (string->path "x64/DirectML.dll")))
    (check-false (windows-release-excluded? (string->path "x64/RivetHost.exe")))
    (check-false (windows-release-excluded? (string->path "x64/libracketcs_ex0znk.dll")))
    (define rc (prepare-windows-icon-resource! project))
    (check-true (file-exists? rc))
    (check-true
     (regexp-match? #rx"IDI_RIVET_APP_ICON ICON"
                    (file->string rc)))
    (check-false (regexp-match? #rx"\\\\" (file->string rc)))
    ;; The version block always ships, icon or not: identity in Explorer,
    ;; Task Manager, and installer UX is not optional for packaged apps.
    (define rc-text (file->string rc))
    (check-true (regexp-match? #rx"#include <windows\\.h>" rc-text))
    (check-true (regexp-match? #rx"VS_VERSION_INFO VERSIONINFO" rc-text))
    (check-true (regexp-match? #rx"FILEVERSION     0, 1, 0, 1" rc-text))
    (check-true
     (regexp-match? #rx"VALUE \"ProductName\",      \"Demo_App\"" rc-text))
    (check-true
     (regexp-match? #rx"VALUE \"OriginalFilename\", \"Demo_App\\.exe\"" rc-text))

    ;; An omitted windows-icon still builds, but must say so: the generic
    ;; icon only surfaces after a user installs, never during CI.
    (define iconless-stderr (open-output-string))
    (define iconless-rc
      (parameterize ([current-error-port iconless-stderr])
        (prepare-windows-icon-resource! (rivet-project temp-root #hasheq((name . "Demo_App"))))))
    (check-false
     (regexp-match? #rx"IDI_RIVET_APP_ICON" (file->string iconless-rc)))
    (check-true
     (regexp-match? #rx"no `windows-icon`" (get-output-string iconless-stderr)))

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
    ;; Without a declaration there is no CFBundleLocalizations key — the
    ;; byte-identical behavior projects without the key have always had.
    (check-false (regexp-match? #rx"CFBundleLocalizations" plist-text))

    ;; Declared localizations land in Info.plist and marker lproj
    ;; directories; the declaration also rejects malformed language tags.
    (define localized-plist (build-path temp-root "Localized-Info.plist"))
    (write-macos-info! localized-plist
                       "Demo"
                       "Demo"
                       "dev.rivet.demo"
                       "1.2.3"
                       7
                       "14.0"
                       #f
                       '()
                       '()
                       '("zh-Hans" "en"))
    (define localized-text (file->string localized-plist))
    (check-true
     (regexp-match?
      #rx"<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>"
      localized-text))
    (check-false
     (regexp-match? #rx"CFBundleLocalizations</key><array><string>zh"
                    (file->string plist)))
    ;; Malformed language tags fail at the declaration, not the writer.
    (define bad-loc-root (build-path temp-root "bad-loc"))
    (make-directory* bad-loc-root)
    (call-with-output-file (build-path bad-loc-root "rivet.rktd")
      (lambda (out)
        (displayln
         "#hasheq((name . \"Demo_App\") (backend . \"app/backend.rkt\") (module . \"backend\") (entry . \"start\") (protocol . 1) (macos-localizations . (\"zh_Hans\")))"
         out)))
    (check-exn #rx"BCP 47"
               (lambda () (load-project bad-loc-root)))

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
                                          (build-path temp-root "linked-stage"))))

    ;; SwiftPM resource bundles cannot ship in a signed .app: Bundle.module
    ;; looks them up at the unsealed .app root, so packaging fails closed.
    (define bundle-stage (build-path temp-root "bundle-stage"))
    (make-directory* (build-path bundle-stage "RivetHost_RivetHost.bundle"))
    (write-text (build-path bundle-stage "RivetHost") "exe")
    (write-text (build-path bundle-stage "notes.txt") "not a bundle")
    (check-equal? (staged-swiftpm-bundles bundle-stage)
                  '("RivetHost_RivetHost.bundle"))
    (check-equal? (staged-swiftpm-bundles
                   (build-path temp-root "missing-stage"))
                  '()))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))
    (when (directory-exists? external-root)
      (delete-directory/files external-root))))
