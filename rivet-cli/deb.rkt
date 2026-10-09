#lang racket/base

;; deb packaging for Linux Rivet apps. Produces a standards-compliant deb
;; from the verified tar.gz package directory without root privileges:
;; dpkg-deb --build --root-owner-group stamps root ownership on every entry
;; (what a real package would carry) while running as the CI user.

(require racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         "linux-native-package.rkt"
         "project.rkt")

(provide deb-installer-path
         stage-deb-root!
         write-deb-control!
         create-deb!)

(define (run! who executable . arguments)
  (unless executable (raise-arguments-error who "required executable was not found"))
  (unless (apply system* executable arguments)
    (raise-arguments-error who
                            "external command failed"
                            "executable" executable
                            "arguments" arguments)))

(define (deb-installer-path project)
  (project-path
   project "dist"
   (format "~a-~a-linux-~a.deb"
           (project-name project)
           (project-version project)
           (deb-architecture))))

(define (installed-size-kib root)
  ;; dpkg control Installed-Size is KiB of the installed payload.
  (quotient (for/sum ([path (in-list (find-files file-exists? root))])
              (file-size path))
            1024))

;; Stages the full deb root: DEBIAN/control, the payload under /opt/<name>,
;; the desktop entry, and the pixmaps icon when the project declares one.
;; Returns the staged root directory.
(define (stage-deb-root! project package [destination #f])
  (define name (project-name project))
  (define root
    (or destination
        (project-path project ".rivet" "installer" "deb-root")))
  (when (directory-exists? root) (delete-directory/files root))
  (define payload-dir (build-path root "opt" name))
  (make-directory* payload-dir)
  ;; Copy entry by entry instead of copy-tree! so the staged root never
  ;; inherits the source's executable bit layout wholesale.
  (for ([entry (in-list (directory-list package))])
    (define source (build-path package entry))
    (if (directory-exists? source)
        (copy-directory/files source (build-path payload-dir entry))
        (copy-file source (build-path payload-dir entry))))
  (write-desktop-entry!
   project
   (build-path root (installed-share-root) "applications"
               (string-append name ".desktop")))
  (stage-native-icon!
   project
   (build-path root (installed-share-root) "pixmaps" (string-append name ".png")))
  (make-directory* (build-path root "DEBIAN"))
  (write-deb-control! project (build-path root "DEBIAN" "control")
                      (installed-size-kib root))
  root)

(define (control-field key value)
  (format "~a: ~a\n" key value))

;; The GTK4 host links gtk4; the embedded Racket runtime and application
;; payload ship inside /opt/<name> and pull no further distribution
;; packages. libgtk-4-1 is the runtime soname package on Debian and Ubuntu.
(define (write-deb-control! project destination [installed-size-kib 0])
  (call-with-output-file destination
    #:exists 'truncate/replace
    (lambda (out)
      (display (control-field "Package" (deb-package-name project)) out)
      (display (control-field "Version"
                              (format "~a-~a"
                                      (project-version project)
                                      (project-build project)))
               out)
      (display (control-field "Architecture" (deb-architecture)) out)
      (display (control-field "Maintainer" (project-publisher project)) out)
      (display (control-field "Section" "utils") out)
      (display (control-field "Priority" "optional") out)
      (display (control-field "Depends" "libgtk-4-1") out)
      (display (control-field "Installed-Size" (~a installed-size-kib)) out)
      ;; Description: first line is the synopsis; continuation lines are
      ;; indented by one space per deb control(5).
      (fprintf out "Description: ~a\n ~a native desktop app powered by Racket and Rivet.\n"
               (project-display-name project)
               (project-display-name project))))
  destination)

(define (create-deb! project package)
  (define dpkg-deb (find-executable-path "dpkg-deb"))
  (unless dpkg-deb
    (error 'create-deb!
           (string-append
            "dpkg-deb was not found; install the dpkg package (present on every"
            " Debian and Ubuntu image) before building the deb installer")))
  (define root (stage-deb-root! project package))
  (define output (deb-installer-path project))
  (make-directory* (path-only output))
  (when (file-exists? output) (delete-file output))
  ;; --root-owner-group keeps the build unprivileged while recording the
  ;; root:root ownership a system package installs with.
  (run! 'create-deb! dpkg-deb
        "--root-owner-group" "--build"
        (path->string root) (path->string output))
  output)

(module+ test-support
  (provide stage-deb-root!
           write-deb-control!
           deb-installer-path))
