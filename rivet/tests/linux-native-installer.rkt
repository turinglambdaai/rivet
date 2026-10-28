#lang racket/base

;; Structural tests for the native Linux installer formats (deb, rpm,
;; AppImage). Staging and metadata generation are pure Racket, so the deb
;; control file, desktop entry, rpm spec, and AppRun script are validated
;; byte-level on any host. The checksum sidecar needs the pinned libcrypto
;; provider; full builds (dpkg-deb, rpmbuild, appimagetool) run in the Linux
;; CI package smoke jobs where the tooling exists.

(require rackunit
         racket/file
         racket/path
         racket/string
         "../../rivet/distribution/crypto.rkt"
         "../../rivet-cli/appimage.rkt"
         (only-in (submod "../../rivet-cli/appimage.rkt" test-support)
                  write-appimage-checksum!)
         "../../rivet-cli/deb.rkt"
         "../../rivet-cli/linux-native-package.rkt"
         "../../rivet-cli/project.rkt"
         "../../rivet-cli/rpm.rkt")

;; Rivet pins manifest crypto to the libcrypto factory, which desktop
;; Racket distributions bundle. Package build hosts may not have a native
;; libcrypto, so the checksum sidecar checks skip there instead of failing.
(define digests-available?
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (sha256-bytes #"")
    #t))

(define temp-root (make-temporary-file "rivet-linux-native-~a" 'directory))

(define (write-bytes/text path text)
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display text out))))

(dynamic-wind
  void
  (lambda ()
    ;; A minimal verified-package layout mirroring package-linux! output.
    (define package-dir (build-path temp-root "demo-linux"))
    (write-bytes/text (build-path package-dir "demo-app") "#!binary")
    (write-bytes/text (build-path package-dir "res" "core.zo") "zo")
    (for ([boot '("petite.boot" "scheme.boot" "racket.boot")])
      (write-bytes/text (build-path package-dir "runtime" boot) "boot"))
    (write-bytes/text (build-path temp-root "branding" "app.png") "png-bytes")

    (define project
      (rivet-project
       temp-root
       #hasheq((name . "Demo_App")
               (display-name . "Demo App")
               (publisher . "Demo Publisher")
               (version . "1.2.0")
               (build . 7)
               (identifier . "dev.rivet.demo")
               ;; Identity consumed by the Wayland GlobalShortcuts portal.
               (linux-desktop-id . "dev.rivet.demo")
               (linux-icon . "branding/app.png")
               (linux-binary-name . "demo-app"))))

    ;; ---------------------------------------------------------- naming
    (check-equal? (deb-package-name project) "demo-app")
    (check-equal? (rpm-package-name project) "Demo_App")
    (check-true (regexp-match? #rx"(?m:-linux-amd64\\.deb$|-linux-arm64\\.deb$)"
                               (path->string (deb-installer-path project))))
    (check-true (regexp-match? #rx"(?m:\\.rpm$)" (path->string (rpm-installer-path project))))
    (check-true (regexp-match? #rx"(?m:\\.AppImage$)"
                               (path->string (appimage-installer-path project))))
    (when digests-available?
      (define checksum-payload (build-path temp-root "Demo_App.AppImage"))
      (write-bytes/text checksum-payload "appimage-bytes")
      (define checksum-sidecar (write-appimage-checksum! checksum-payload))
      (check-equal?
       (string-trim (file->string checksum-sidecar))
       (format "~a  Demo_App.AppImage"
               (sha256-file/hex checksum-payload))))

    ;; ------------------------------------------------------------- deb
    (define deb-root (stage-deb-root! project package-dir
                                      (build-path temp-root "deb-root")))
    (check-true (file-exists? (build-path deb-root "opt" "Demo_App" "demo-app")))
    (check-true (file-exists? (build-path deb-root "opt" "Demo_App" "res" "core.zo")))
    (define desktop
      (file->string (build-path deb-root "usr" "share" "applications"
                                "dev.rivet.demo.desktop")))
    (check-equal? (project-linux-desktop-id project) "dev.rivet.demo")
    (check-true (regexp-match? #rx"(?m:^Type=Application$)" desktop))
    (check-true (regexp-match? #rx"(?m:^Exec=/opt/Demo_App/demo-app$)" desktop))
    (check-true (regexp-match? #rx"(?m:^TryExec=/opt/Demo_App/demo-app$)" desktop))
    (check-true (regexp-match? #rx"(?m:^Icon=Demo_App$)" desktop))
    (check-true (file-exists? (build-path deb-root "usr" "share" "pixmaps"
                                           "Demo_App.png")))
    (define control
      (file->string (build-path deb-root "DEBIAN" "control")))
    (check-true (regexp-match? #rx"(?m:^Package: demo-app$)" control))
    (check-true (regexp-match? #rx"(?m:^Version: 1\\.2\\.0-7$)" control))
    (check-true (regexp-match? #rx"(?m:^Depends: libgtk-4-1$)" control))
    (check-true (regexp-match? #rx"(?m:^Architecture: (amd64|arm64)$)" control))
    (for ([script-name (in-list '("postinst" "postrm"))])
      (define script (build-path deb-root "DEBIAN" script-name))
      (check-true (file-exists? script)
                  "desktop database refresh scripts must ship with the deb")
      (check-true
       (regexp-match? #rx"update-desktop-database" (file->string script))
       "maintainer scripts must refresh the desktop database")
      ;; Unix permission bits do not exist on NTFS: everything reports
      ;; 0o777 there, so the 0o755 assertion is only meaningful on POSIX.
      (when (memq (system-type 'os) '(unix macosx))
        (check-equal? (file-or-directory-permissions script 'bits) 493
                      "maintainer scripts must be executable (0o755)")))

    ;; ------------------------------------------------------------- rpm
    (define spec-path (build-path temp-root "demo.spec"))
    (write-rpm-spec! project spec-path)
    (define spec (file->string spec-path))
    (check-true (regexp-match? #rx"(?m:^Name: Demo_App$)" spec))
    (check-true (regexp-match? #rx"(?m:^Version: 1\\.2\\.0$)" spec))
    (check-true (regexp-match? #rx"(?m:^Release: 7$)" spec))
    (check-true (string-contains? spec "/usr/share/applications/dev.rivet.demo.desktop"))
    (check-true (regexp-match? #rx"(?m:^Requires: gtk4$)" spec))
    (check-true (regexp-match? #rx"(?m:^Requires: ncurses-libs$)" spec))
    (check-true
     (string-contains?
      spec
      "%global __requires_exclude ^libtinfo\\\\.so\\\\.6\\\\(NCURSES6_TINFO_.*$"))
    (check-true (regexp-match? #rx"\"/opt/Demo_App/\\*\"" spec))
    ;; System-owned directories must not be re-owned by the package.
    (check-false (regexp-match? #rx"%dir \"/usr/share/applications\"" spec))
    (check-false (regexp-match? #rx"%dir \"/usr/share/pixmaps\"" spec))
    (check-true (regexp-match? #rx"%dir \"/opt/Demo_App\"" spec))

    ;; -------------------------------------------------------- AppImage
    (define appdir (stage-appdir! project package-dir))
    (check-true (file-exists? (build-path appdir "usr" "bin" "demo-app")))
    (check-true (file-exists? (build-path appdir "usr" "bin" "res" "core.zo")))
    (check-true (file-exists? (build-path appdir "dev.rivet.demo.desktop")))
    (check-true (file-exists? (build-path appdir "Demo_App.png")))
    (define apprun (file->string (build-path appdir "AppRun")))
    (check-true (regexp-match? #rx"LD_LIBRARY_PATH" apprun))
    (check-true (regexp-match? #rx"GSETTINGS_SCHEMA_DIR" apprun))
    (check-true (regexp-match? #rx"exec \"\\$\\{HERE\\}/usr/bin/demo-app\"" apprun))

    ;; The AppImage format requires a real icon; fail closed without one.
    (define iconless
      (rivet-project temp-root
                     #hasheq((name . "Demo_App")
                             (display-name . "Demo App")
                             (publisher . "Demo Publisher")
                             (version . "1.2.0")
                             (build . 7)
                             (identifier . "dev.rivet.demo")
                             (linux-binary-name . "demo-app"))))
    (check-exn #rx"linux-icon"
               (lambda ()
                 (stage-appdir! iconless package-dir)))

    ;; deb and rpm install without an icon rather than failing, but the
    ;; desktop entry has to say so at build time.
    (define iconless-stderr (open-output-string))
    (parameterize ([current-error-port iconless-stderr])
      (write-desktop-entry! iconless (build-path temp-root "iconless.desktop")))
    (check-true
     (regexp-match? #rx"no `linux-icon`" (get-output-string iconless-stderr)))

    ;; ------------------------------------------------ linux-formats config
    (check-equal? (project-linux-formats project) '("deb" "rpm" "appimage"))
    (define deb-only
      (rivet-project temp-root
                     #hasheq((name . "Demo_App")
                             (linux-formats . ("deb")))))
    (check-equal? (project-linux-formats deb-only) '("deb"))
    ;; Existing Rivet projects without the override must retain the legacy
    ;; product-name desktop path; only opted-in projects switch identities.
    (check-equal? (project-linux-desktop-id deb-only) "Demo_App"))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
