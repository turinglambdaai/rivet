#lang racket/base

;; rpm packaging for Linux Rivet apps. Builds with rpmbuild -bb from a
;; generated spec and a BUILDROOT staged from the verified tar.gz package
;; directory — no root privileges, no distro-specific macros (no %dist tag,
;; so one rpm validates on any rpm-based distribution).

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         "linux-native-package.rkt"
         "project.rkt")

(provide rpm-installer-path
         write-rpm-spec!
         create-rpm!)

(define (run! who executable . arguments)
  (unless executable (raise-arguments-error who "required executable was not found"))
  (unless (apply system* executable arguments)
    (raise-arguments-error who
                            "external command failed"
                            "executable" executable
                            "arguments" arguments)))

(define (rpm-installer-path project)
  (project-path
   project "dist"
   (format "~a-~a-~a~a-linux-~a.rpm"
           (project-name project)
           (project-version project)
           (project-build project)
           (rpm-release-suffix project)
           (rpm-architecture))))

;; An explicit release suffix is only needed when the same build number is
;; published twice; the build number already increments per release, so the
;; suffix stays empty.
(define (rpm-release-suffix project)
  "")

;; Spec generation is separated so tests can validate the metadata without
;; rpmbuild installed. System-owned directories (/usr/share/applications,
;; /usr/share/pixmaps) are deliberately NOT declared: they belong to the
;; filesystem package, and re-owning them is a classic packaging defect.
;; /opt/<name> is ours, so it gets an explicit %dir entry and uninstalls
;; cleanly.
(define (write-rpm-spec! project destination)
  (define name (project-name project))
  (call-with-output-file destination
    #:exists 'truncate/replace
    (lambda (out)
      (define (tag key value)
        (fprintf out "~a: ~a\n" key value))
      (tag "Name" (rpm-package-name project))
      (tag "Version" (project-version project))
      (tag "Release" (format "~a" (project-build project)))
      (tag "Summary"
           (format "~a native desktop app powered by Racket and Rivet"
                   (project-display-name project)))
      ;; Rivet apps carry their own licensing; products set their terms.
      (tag "License" "Proprietary")
      (tag "URL" "https://github.com/turinglambdaai/rivet")
      (tag "BuildArch" (rpm-architecture))
      (tag "Requires" "gtk4")
      (display "\n%description\n" out)
      (fprintf out "~a native desktop app. The application payload and the\n"
               (project-display-name project))
      (display "embedded Racket runtime install self-contained under /opt.\n" out)
      ;; Empty build stages: the BUILDROOT is staged directly by Rivet.
      (display "\n%prep\n\n%build\n\n%install\n" out)
      (display "\n%files\n" out)
      (fprintf out "%dir \"/opt/~a\"\n" name)
      (fprintf out "\"/opt/~a/*\"\n" name)
      (fprintf out "\"/usr/share/applications/~a.desktop\"\n" name)
      (when (project-linux-icon project)
        (fprintf out "\"/usr/share/pixmaps/~a.png\"\n" name))))
  destination)

(define (create-rpm! project package)
  (define rpmbuild (find-executable-path "rpmbuild"))
  (unless rpmbuild
    (error 'create-rpm!
           (string-append
            "rpmbuild was not found; install rpm-build (dnf install rpm-build"
            " or apt-get install rpm) before building the rpm installer")))
  (define name (project-name project))
  (define topdir (project-path project ".rivet" "installer" "rpm"))
  (when (directory-exists? topdir) (delete-directory/files topdir))
  (define buildroot (build-path topdir "BUILDROOT"))
  (define spec-dir (build-path topdir "SPECS"))
  (make-directory* (build-path buildroot "opt" name))
  (make-directory* spec-dir)
  ;; BUILDROOT mirrors the installed filesystem, staged from the verified
  ;; package directory plus the shared desktop/icon metadata.
  (for ([entry (in-list (directory-list package))])
    (define source (build-path package entry))
    (if (directory-exists? source)
        (copy-directory/files source (build-path buildroot "opt" name entry))
        (copy-file source (build-path buildroot "opt" name entry))))
  (write-desktop-entry!
   project
   (build-path buildroot (installed-share-root) "applications"
               (string-append name ".desktop")))
  (stage-native-icon!
   project
   (build-path buildroot (installed-share-root) "pixmaps"
               (string-append name ".png")))
  (define spec (build-path spec-dir (string-append name ".spec")))
  (write-rpm-spec! project spec)
  (define output (rpm-installer-path project))
  (make-directory* (path-only output))
  (when (file-exists? output) (delete-file output))
  (run! 'create-rpm! rpmbuild
        "-bb"
        (string-append "--define=_topdir " (path->string topdir))
        (string-append "--define=buildroot " (path->string buildroot))
        (string-append "--define=_rpmdir " (path->string (project-path project "dist")))
        (string-append "--define=_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm")
        (path->string spec))
  (when (file-exists? output) (delete-file output))
  (define built
    (build-path (project-path project "dist")
                (format "~a-~a-~a~a.~a.rpm"
                        (rpm-package-name project)
                        (project-version project)
                        (project-build project)
                        (rpm-release-suffix project)
                        (rpm-architecture))))
  (unless (file-exists? built)
    (error 'create-rpm! "rpmbuild did not produce the expected rpm" built))
  (rename-file-or-directory built output #t)
  output)

(module+ test-support
  (provide write-rpm-spec!
           rpm-installer-path))
