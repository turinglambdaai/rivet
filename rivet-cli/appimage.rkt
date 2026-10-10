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
         "../rivet/distribution/crypto.rkt"
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
  ;; Redirect both streams instead of draining process* pipes serially: a
  ;; verbose stderr must never block a child whose stdout is being captured.
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define status
    (parameterize ([current-output-port stdout]
                   [current-error-port stderr])
      (apply system*/exit-code executable arguments)))
  (unless (zero? status)
    (raise-arguments-error
     who
     "external command failed"
     "executable" executable
     "arguments" arguments
     "exit-code" status
     "stderr" (string-trim (get-output-string stderr))))
  (get-output-string stdout))

(define (appimage-installer-path project)
  (project-path
   project "dist"
   (format "~a-~a-linux-~a.AppImage"
           (project-name project)
           (project-version project)
           (appimage-architecture))))

(define (write-appimage-checksum! output)
  (define sidecar (string->path (string-append (path->string output) ".sha256")))
  (call-with-output-file sidecar
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "~a  ~a~n"
               (sha256-file/hex output)
               (path->string (file-name-from-path output)))))
  sidecar)

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
(define (stage-appimage-dependencies! appdir
                                      #:binary-name [binary-name "RivetHost"])
  (define payload-binary (build-path appdir "usr" "bin" binary-name))
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
    ;; Carry the version segment alongside the loaders path: deriving it
    ;; back from the path fails because path-only keeps a trailing
    ;; separator, which file-name-from-path rejects.
    (define loaders
      (for/or ([version-dir (in-list (sort (directory-list pixbuf-root) string<? #:key path->string))]
               #:when (directory-exists? (build-path pixbuf-root version-dir "loaders")))
        (cons (path->string version-dir)
              (build-path pixbuf-root version-dir "loaders"))))
    (when (and loaders (absolute-path? (cdr loaders)))
      ;; Keep the loader directory's own version segment in the AppDir path
      ;; so GDK_PIXBUF_MODULEDIR points at a conventional layout.
      (define destination
        (build-path appdir "usr" "lib" "gdk-pixbuf-2.0" (car loaders) "loaders"))
      (make-directory* destination)
      (for ([entry (in-list (directory-list (cdr loaders)))])
        (define source (build-path (cdr loaders) entry))
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
  (printf "rivet: AppImage dependency closure: ~a libraries bundled\n"
          (length libraries))
  libraries)

(define (machine-suffix)
  (case (system-type 'arch)
    [(aarch64 arm64) "aarch64"]
    [else "x86_64"]))

;; POSIX exec bits are meaningless on Windows, where staging runs in tests.
(define (mark-executable! path)
  (unless (eq? (system-type 'os) 'windows)
    (file-or-directory-permissions path #o755)))

(define (write-appimage-apprun! appdir #:binary-name [binary-name "RivetHost"])
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
        (format "exec \"${HERE}/usr/bin/~a\" \"$@\"\n" binary-name))
       out)))
  (mark-executable! (build-path appdir "AppRun")))

(define (stage-appdir! project package)
  (define name (project-name project))
  (define binary-name (project-linux-binary-name project))
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
  (mark-executable! (build-path appdir "usr" "bin" binary-name))
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
  (write-appimage-apprun! appdir #:binary-name binary-name)
  appdir)

;; Fetches a checksum-verified appimagetool into .rivet/bin. The digests
;; are pinned per architecture for the release above (recorded from the
;; published 1.9.0 assets); RIVET_APPIMAGETOOL_PATH bypasses the download
;; for offline builds.
(define appimagetool-digests
  '(("x86_64" . "46fdd785094c7f6e545b61afcfb0f3d98d8eab243f644b4b17698c01d06083d1")
    ("aarch64" . "04f45ea45b5aa07bb2b071aed9dbf7a5185d3953b11b47358c1311f11ea94a96")))

(define (appimagetool-executable project)
  (define override (getenv "RIVET_APPIMAGETOOL_PATH"))
  (cond
    [(and override (file-exists? override)) (string->path override)]
    [else
     (define arch (appimage-architecture))
     (define tool
       (project-path project ".rivet" "bin"
                     (format "appimagetool-~a.AppImage" arch)))
     (unless (file-exists? tool)
       (define url
         (format "https://github.com/AppImage/appimagetool/releases/download/~a/appimagetool-~a.AppImage"
                 appimagetool-version arch))
       (define curl (find-executable-path "curl"))
       (unless curl
         (error 'create-appimage!
                "curl was not found; it is required to fetch appimagetool, or set RIVET_APPIMAGETOOL_PATH"))
       (make-directory* (path-only tool))
       (run! 'create-appimage! curl "-fSL" "-o" (path->string tool) url)
       ;; Verify against the pinned digest: the download origin is a public
       ;; CDN, so the archive must bit-for-bit match what Rivet expects
       ;; regardless of transport.
       (define expected (cdr (assoc arch appimagetool-digests)))
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
  ;; appimagetool validates the desktop entry through desktop-file-validate
  ;; and exits with a bare code when the helper is absent, hiding the cause.
  (unless (find-executable-path "desktop-file-validate")
    (error 'create-appimage!
           (string-append
            "desktop-file-validate was not found; appimagetool requires it"
            " to validate the desktop entry (apt-get install"
            " desktop-file-utils or dnf install desktop-file-utils) before"
            " building the AppImage")))
  (printf "rivet: staging AppDir for the AppImage installer\n")
  (define appdir (stage-appdir! project package))
  (stage-appimage-dependencies!
   appdir
   #:binary-name (project-linux-binary-name project))
  (printf "rivet: packaging the AppImage with appimagetool\n")
  (define tool (appimagetool-executable project))
  (define output (appimage-installer-path project))
  (make-directory* (path-only output))
  (when (file-exists? output) (delete-file output))
  (putenv "APPIMAGE_EXTRACT_AND_RUN" "1")
  (run! 'create-appimage! tool (path->string appdir) (path->string output))
  (write-appimage-checksum! output)
  output)

(module+ test-support
  (provide stage-appdir!
           write-appimage-apprun!
           write-appimage-checksum!
           appimage-installer-path
           run/capture))
