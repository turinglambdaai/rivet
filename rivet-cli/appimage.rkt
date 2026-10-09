#lang racket/base

;; AppImage packaging for Linux Rivet apps.
;;
;; An AppImage must run on distributions older than the build image, so the
;; GTK4 stack the host links is bundled into the AppDir as a dependency
;; closure (ldd, transitively) minus the libc/loader/GL driver surface that
;; must come from the host. GSettings schemas are compiled in and pixbuf
;; loaders staged, and AppRun points GLib/GTK at them. appimagetool runs
;; with APPIMAGE_EXTRACT_AND_RUN=1 so no FUSE is required on build machines
;; (CI runners exclude libfuse2 by default).

(require racket/file
         racket/format
         racket/path
         racket/port
         racket/set
         racket/string
         racket/system
         "linux-native-package.rkt"
         "project.rkt")

(provide appimage-installer-path
         write-appimage-apprun!
         stage-appimage-dependencies!
         stage-appdir!
         create-appimage!)

(define appimagetool-version "1.9.0")

(define (run! who executable . arguments)
  (unless executable (raise-arguments-error who "required executable was not found"))
  (unless (apply system* executable arguments)
    (raise-arguments-error who
                            "external command failed"
                            "executable" executable
                            "arguments" arguments)))

(define (run/capture who executable arguments)
  (unless executable
    (raise-arguments-error who "required executable was not found"))
  ;; process* documents five return values but hands back a five-element
  ;; list on current Racket CS builds; accept either shape.
  (define-values (stdout stdin pid stderr control)
    (call-with-values
        (lambda () (apply process* executable arguments))
      (case-lambda
        [(result) (apply values result)]
        [(a b c d e) (values a b c d e)])))
  (define output (port->string stdout))
  (close-input-port stdout)
  (close-input-port stderr)
  (close-output-port stdin)
  (control 'wait)
  output)

(define (appimage-installer-path project)
  (project-path
   project "dist"
   (format "~a-~a-linux-~a.AppImage"
           (project-name project)
           (project-version project)
           (appimage-architecture))))

;; Libraries that must remain the host system's own: the dynamic loader and
;; libc family, and the GL/Vulkan driver stack (the display driver owns it).
;; libstdc++/libgcc are bundled on purpose — old distributions ship older
;; runtimes than the CI image's compiler targets.
(define host-system-library-pattern
  #px"(^lib(ld-linux|c|m|pthread|dl|rt|resolv|util|nsl|anl|BrokenLocale|gcc_s)\\.so|^lib(GL|EGL|GLX|GLES|glvnd|vulkan|drm)\\.so)")

(define (host-system-library? path)
  (regexp-match? host-system-library-pattern (path->string (file-name-from-path path))))

;; Resolves the ldd dependency closure of a binary, breadth-first, skipping
;; host-system libraries and anything already staged.
(define (dependency-closure executable)
  (define ldd (find-executable-path "ldd"))
  (unless ldd
    (error 'stage-appimage-dependencies!
           "ldd was not found; AppImage bundling requires binutils"))
  (define queue (list executable))
  (define seen (mutable-set))
  (define libraries '())
  (let loop ()
    (unless (null? queue)
      (define binary (car queue))
      (set! queue (cdr queue))
      (when (and (file-exists? binary) (not (set-member? seen binary)))
        (set-add! seen binary)
        (define text (run/capture 'stage-appimage-dependencies! ldd (list (path->string binary))))
        (for ([line (in-list (string-split text "\n"))])
          (define resolved
            (cond
              [(regexp-match #px"=>\\s+(\\S+)\\s+\\(" line) => cadr]
              [(regexp-match #px"^\\s*(/\\S+)\\s+\\(" line) => cadr]
              [else #f]))
          (when (and resolved
                     (file-exists? resolved)
                     (not (host-system-library? resolved))
                     (not (set-member? seen resolved)))
            (set-add! seen resolved)
            (set! libraries (cons resolved libraries))
            (set! queue (append queue (list (string->path resolved))))))
        (loop))))
  (reverse libraries))

;; Stages the dependency closure plus the data directories GTK4 needs at
;; runtime (compiled GSettings schemas, pixbuf loaders, a minimal hicolor
;; index) into the AppDir. Returns the list of copied libraries.
(define (stage-appimage-dependencies! appdir)
  (define payload-binary (build-path appdir "usr" "bin" "RivetHost"))
  (define lib-dir (build-path appdir "usr" "lib"))
  (make-directory* lib-dir)
  (define libraries (dependency-closure payload-binary))
  (for ([library (in-list libraries)])
    (copy-file library (build-path lib-dir (file-name-from-path library)) #t))

  ;; GSettings schemas: copy the XML sources and compile in place.
  (define schema-source (build-path "/usr" "share" "glib-2.0" "schemas"))
  (when (directory-exists? schema-source)
    (define schema-dir (build-path appdir "usr" "share" "glib-2.0" "schemas"))
    (make-directory* schema-dir)
    (for ([entry (in-list (directory-list schema-source))]
          #:when (regexp-match? #px"[.]xml$" (path->string entry)))
      (copy-file (build-path schema-source entry)
                 (build-path schema-dir entry) #t))
    (define glib-compile-schemas (find-executable-path "glib-compile-schemas"))
    (when glib-compile-schemas
      (run! 'stage-appimage-dependencies! glib-compile-schemas
            (path->string schema-dir))))

  ;; gdk-pixbuf loaders: stage the loader cache directory when present.
  (define pixbuf-root
    (for/or ([candidate (in-list (list (build-path "/usr" "lib" (format "~a-linux-gnu" (machine-suffix))
                                                        "gdk-pixbuf-2.0")
                                      (build-path "/usr" "lib64" "gdk-pixbuf-2.0")
                                      (build-path "/usr" "lib" "gdk-pixbuf-2.0")))]
             #:when (directory-exists? candidate))
      candidate))
  (when pixbuf-root
    (define loaders
      (for/or ([version-dir (in-list (sort (directory-list pixbuf-root) string<? #:key path->string))]
               #:when (directory-exists? (build-path pixbuf-root version-dir "loaders")))
        (build-path pixbuf-root version-dir)))
    (when loaders
      (define destination
        (build-path appdir "usr" "lib" "gdk-pixbuf-2.0"
                    (file-name-from-path (path-only loaders))
                    "loaders"))
      (make-directory* destination)
      (for ([entry (in-list (directory-list loaders))])
        (define source (build-path loaders entry))
        (when (file-exists? source)
          (copy-file source (build-path destination entry) #t)))))

  ;; Minimal hicolor theme so GTK's icon theme initialization always finds
  ;; an index even on minimal window managers.
  (define hicolor (build-path appdir "usr" "share" "icons" "hicolor"))
  (make-directory* hicolor)
  (call-with-output-file (build-path hicolor "index.theme")
    #:exists 'truncate/replace
    (lambda (out)
      (display "[Icon Theme]\nName=Hicolor\n" out)))
  libraries)

(define (machine-suffix)
  (case (system-type 'arch)
    [(aarch64 arm64) "aarch64"]
    [else "x86_64"]))

;; POSIX exec bits are meaningless on Windows, where staging runs in tests.
(define (mark-executable! path)
  (unless (eq? (system-type 'os) 'windows)
    (file-or-directory-permissions path #o755)))

(define (write-appimage-apprun! appdir)
  (call-with-output-file (build-path appdir "AppRun")
    #:exists 'truncate/replace
    (lambda (out)
      (display
       (string-append
        "#!/bin/sh\n"
        "# Rivet AppImage entry point. Bundled GTK/GLib stack under usr/lib,\n"
        "# compiled schemas and pixbuf loaders shipped inside the AppDir.\n"
        "HERE=\"$(dirname \"$(readlink -f \"$0\")\")\"\n"
        "export LD_LIBRARY_PATH=\"${HERE}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}\"\n"
        "export GSETTINGS_SCHEMA_DIR=\"${HERE}/usr/share/glib-2.0/schemas\"\n"
        "LOADERS=\"$(find \"${HERE}/usr/lib/gdk-pixbuf-2.0\" -type d -name loaders 2>/dev/null | head -n 1)\"\n"
        "if [ -n \"$LOADERS\" ]; then\n"
        "  export GDK_PIXBUF_MODULEDIR=\"$LOADERS\"\n"
        "fi\n"
        "export XDG_DATA_DIRS=\"${HERE}/usr/share${XDG_DATA_DIRS:+:${XDG_DATA_DIRS}}\"\n"
        "exec \"${HERE}/usr/bin/RivetHost\" \"$@\"\n")
       out)))
  (mark-executable! (build-path appdir "AppRun")))

(define (stage-appdir! project package)
  (define name (project-name project))
  (define appdir
    (project-path project ".rivet" "installer"
                  (string-append name ".AppDir")))
  (when (directory-exists? appdir) (delete-directory/files appdir))
  (make-directory* (build-path appdir "usr" "bin"))
  ;; Payload keeps its RivetHost-relative layout (runtime/, res/, app/ sit
  ;; beside the executable) because the embedded runtime resolves those
  ;; relative to the binary location.
  (for ([entry (in-list (directory-list package))])
    (define source (build-path package entry))
    (if (directory-exists? source)
        (copy-directory/files source (build-path appdir "usr" "bin" entry))
        (copy-file source (build-path appdir "usr" "bin" entry))))
  (mark-executable! (build-path appdir "usr" "bin" "RivetHost"))
  (write-desktop-entry! project (build-path appdir (string-append name ".desktop")))
  ;; Fail closed: the AppImage format requires a top-level icon, and a
  ;; placeholder would ship an invisible product tile to users' app grids.
  (unless (project-linux-icon project)
    (error 'stage-appdir!
           (string-append
            "the AppImage format requires a top-level icon PNG; declare"
            " `linux-icon` (a project-relative .png) in rivet.rktd")))
  (copy-file (project-path project (project-linux-icon project))
             (build-path appdir (string-append name ".png")) #t)
  (write-appimage-apprun! appdir)
  appdir)

;; Fetches a checksum-verified appimagetool into .rivet/bin. The digest is
;; read from the GitHub release API at download time (no hard-coded hash to
;; rot); RIVET_APPIMAGETOOL_PATH bypasses the download for offline builds.
(define (appimagetool-executable project)
  (define override (getenv "RIVET_APPIMAGETOOL_PATH"))
  (cond
    [(and override (file-exists? override)) (string->path override)]
    [else
     (define tool
       (project-path project ".rivet" "bin"
                     (format "appimagetool-~a.AppImage" (appimage-architecture))))
     (unless (file-exists? tool)
       (define arch (appimage-architecture))
       (define url
         (format "https://github.com/AppImage/appimagetool/releases/download/~a/appimagetool-~a.AppImage"
                 appimagetool-version arch))
       (define curl (find-executable-path "curl"))
       (unless curl
         (error 'create-appimage!
                "curl was not found; it is required to fetch appimagetool, or set RIVET_APPIMAGETOOL_PATH"))
       (make-directory* (path-only tool))
       (run! 'create-appimage! curl "-fSL" "-o" (path->string tool) url)
       ;; Verify against the GitHub-published asset digest (sha256:…).
       (define api
         (format "https://api.github.com/repos/AppImage/appimagetool/releases/tags/~a"
                 appimagetool-version))
       (define metadata
         (run/capture 'create-appimage! curl (list "-fsSL" api)))
       (define expected
         (cond [(regexp-match #px"\"digest\":\\s*\"sha256:([0-9a-f]{64})\"" metadata)
                => cadr]
               [else
                (error 'create-appimage!
                       "could not read the appimagetool asset digest from the GitHub API")]))
       (define sha256sum (find-executable-path "sha256sum"))
       (unless sha256sum
         (error 'create-appimage! "sha256sum was not found for appimagetool verification"))
       (define actual
         (car (string-split (run/capture 'create-appimage!
                                         sha256sum
                                         (list (path->string tool))))))
       (unless (string-ci=? (string-trim actual) expected)
         (delete-file tool)
         (error 'create-appimage!
                "appimagetool download failed checksum verification"
                "expected" expected "actual" actual)))
     (file-or-directory-permissions tool #o755)
     tool]))

(define (create-appimage! project package)
  (define appdir (stage-appdir! project package))
  (stage-appimage-dependencies! appdir)
  (define tool (appimagetool-executable project))
  (define output (appimage-installer-path project))
  (make-directory* (path-only output))
  (when (file-exists? output) (delete-file output))
  (putenv "APPIMAGE_EXTRACT_AND_RUN" "1")
  (run! 'create-appimage! tool (path->string appdir) (path->string output))
  output)

(module+ test-support
  (provide stage-appdir!
           write-appimage-apprun!
           appimage-installer-path))
