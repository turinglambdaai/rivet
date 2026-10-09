#lang racket/base

(require racket/file
         racket/format
         racket/path
         racket/string
         "project.rkt")

;; Shared naming, metadata, and staging pieces for the native Linux package
;; formats (deb, rpm, AppImage). Kept free of external-tool invocations so the
;; packager, installer, verifier, and tests agree on one layout without a
;; require cycle.

(provide deb-package-name
         deb-architecture
         rpm-package-name
         rpm-architecture
         appimage-architecture
         write-desktop-entry!
         stage-native-icon!
         installed-share-root)

;; deb package names are lower-case [a-z0-9][a-z0-9+.-]*; project names may
;; contain capitals or underscores, so fold them per convention. The install
;; path (/opt/<name>) keeps the project spelling.
(define (deb-package-name project)
  (define folded
    (regexp-replace* #px"[^a-z0-9+.-]"
                     (string-downcase (project-name project))
                     "-"))
  (if (regexp-match? #px"^[a-z0-9]" folded)
      folded
      (string-append "app-" folded)))

;; Debian architecture naming: x86_64 is amd64, aarch64 is arm64.
(define (deb-architecture)
  (case (system-type 'arch)
    [(aarch64 arm64) "arm64"]
    [else "amd64"]))

(define (rpm-package-name project)
  (regexp-replace* #px"[^a-zA-Z0-9._+-]" (project-name project) "-"))

;; rpm architecture naming matches the toolchain triple.
(define (rpm-architecture)
  (case (system-type 'arch)
    [(aarch64 arm64) "aarch64"]
    [else "x86_64"]))

(define (appimage-architecture)
  (case (system-type 'arch)
    [(aarch64 arm64) "aarch64"]
    [else "x86_64"]))

;; Installed payload layout shared by deb and rpm: the verified tar.gz
;; package directory lands under /opt/<name>, icons under the legacy
;; /usr/share/pixmaps root (size-independent, honored by every desktop
;; environment), and the desktop entry under /usr/share/applications.
(define (installed-share-root)
  "usr/share")

(define (write-desktop-entry! project destination)
  (define name (project-name project))
  (define display-name (project-display-name project))
  (make-parent-directory* destination)
  (call-with-output-file destination
    #:exists 'truncate/replace
    (lambda (out)
      (define (entry key value)
        (fprintf out "~a=~a\n" key value))
      (display "[Desktop Entry]\n" out)
      (entry "Type" "Application")
      (entry "Version" "1.0")
      (entry "Name" display-name)
      (entry "Exec" (format "/opt/~a/RivetHost" name))
      (entry "TryExec" (format "/opt/~a/RivetHost" name))
      (entry "Terminal" "false")
      (entry "Categories" "Utility;")
      (when (project-linux-icon project)
        (entry "Icon" name)))))

(define (stage-native-icon! project destination)
  ;; Returns #t when an icon was staged. Sized hicolor themes are not used
  ;; because the source PNG resolution is not known here; pixmaps covers all.
  (define icon (project-linux-icon project))
  (cond
    [icon
     (make-parent-directory* destination)
     (copy-file (project-path project icon) destination #t)
     #t]
    [else #f]))

(module+ test-support
  (provide write-desktop-entry!
           stage-native-icon!
           deb-package-name
           deb-architecture
           rpm-package-name
           rpm-architecture
           appimage-architecture))
