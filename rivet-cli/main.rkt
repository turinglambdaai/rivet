#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/string)

(define (say fmt . args)
  (apply printf (string-append "rivet: " fmt "\n") args))

(define (die fmt . args)
  (apply eprintf (string-append "rivet: error: " fmt "\n") args)
  (exit 1))

(define (usage)
  (displayln
   (string-append
    "Rivet — build native desktop apps with Racket\n\n"
    "Usage:\n"
    "  raco rivet new <name>      create a new Rivet application\n"
    "  raco rivet doctor          inspect the local native toolchain\n"
    "  raco rivet dev             build and run the current app (planned)\n"
    "  raco rivet build           build the current app (planned)\n"
    "  raco rivet package         package the current app (planned)\n"
    "  raco rivet help            show this help\n")))

(define (safe-project-name? s)
  (and (regexp-match? #px"^[A-Za-z][A-Za-z0-9_-]*$" s)
       (not (member s '("." "..")))))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists 'error
    (lambda (out) (display text out))))

(define (project-readme name)
  (format "# ~a\n\nA native desktop app powered by Racket and Rivet.\n\n## Backend\n\nEdit `app/backend.rkt`, then run `raco rivet doctor`.\n\nNative build/run commands will use WinUI 3 on Windows and SwiftUI on macOS.\n"
          name))

(define backend-template
  #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value Int64] : Int64)
  (add1 value))

;; Native hosts pass CRT file descriptors owned by Rivet's transport bridge.
(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
  )

(define (config-template name)
  (format "#hasheq((name . ~s) (backend . \"app/backend.rkt\") (module . \"backend\") (entry . \"start\") (protocol . 1))\n"
          name))

(define (new-project name)
  (unless (safe-project-name? name)
    (die "invalid project name ~s; use letters, digits, '-' or '_'" name))
  (define root (build-path (current-directory) name))
  (when (directory-exists? root)
    (die "directory already exists: ~a" root))
  (make-directory* root)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (directory-exists? root)
                       (delete-directory/files root))
                     (raise e))])
    (write-text (build-path root "README.md") (project-readme name))
    (write-text (build-path root "rivet.rktd") (config-template name))
    (write-text (build-path root "app" "backend.rkt") backend-template)
    (write-text (build-path root ".gitignore")
                ".rivet/\nbuild/\ndist/\n.DS_Store\n")
    (make-directory* (build-path root "platform" "windows"))
    (make-directory* (build-path root "platform" "macos")))
  (say "created ~a" name)
  (displayln "")
  (displayln (format "  cd ~a" name))
  (displayln "  raco rivet doctor"))

(define (tool-status label executable)
  (define found (find-executable-path executable))
  (printf "  ~a: ~a\n" label (if found (path->string found) "not found"))
  (and found #t))

(define (doctor)
  (printf "Rivet doctor\n\n")
  (printf "  OS: ~a\n" (system-type 'os))
  (printf "  architecture: ~a\n" (system-type 'arch))
  (printf "  Racket: ~a\n" (version))
  (define common-ok? (tool-status "raco" "raco"))
  (define native-ok?
    (case (system-type 'os)
      [(windows)
       (let ([msbuild? (tool-status "MSBuild" "MSBuild.exe")]
             [cl? (tool-status "C++ compiler" "cl.exe")])
         (printf "  UI: WinUI 3 / Windows App SDK\n")
         (and msbuild? cl?))]
      [(macosx)
       (let ([swift? (tool-status "Swift" "swift")]
             [xcode? (tool-status "Xcode build" "xcodebuild")])
         (printf "  UI: SwiftUI / AppKit\n")
         (and swift? xcode?))]
      [else
       (printf "  UI: unsupported (Rivet currently targets Windows and macOS)\n")
       #f]))
  (newline)
  (if (and common-ok? native-ok?)
      (begin (say "toolchain looks usable") 0)
      (begin (say "toolchain is incomplete") 1)))

(define args (vector->list (current-command-line-arguments)))

(match args
  [(or '() (list "help") (list "--help") (list "-h"))
   (usage)]
  [(list "new" name)
   (new-project name)]
  [(list "doctor")
   (exit (doctor))]
  [(list (or "dev" "build" "package") _ ...)
   (die "this command is not wired yet; runtime/host integration is the current milestone")]
  [_
   (usage)
   (exit 1)])
