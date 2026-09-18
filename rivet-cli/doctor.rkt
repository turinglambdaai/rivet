#lang racket/base

(require "runtime.rkt"
         "windows-tools.rkt")

(provide run-doctor)

(define (tool-status label executable)
  (define found (find-executable-path executable))
  (printf "  ~a: ~a\n" label (if found found "not found"))
  (and found #t))

(define (run-doctor)
  (printf "Rivet doctor\n\n")
  (printf "  OS: ~a\n" (system-type 'os))
  (printf "  architecture: ~a\n" (system-type 'arch))
  (printf "  Racket: ~a\n" (version))
  (define raco? (tool-status "raco" "raco"))

  (define runtime
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (printf "  Racket runtime: error — ~a\n" (exn-message e))
                       #f)])
      (discover-racket-runtime)))

  (when runtime
    (printf "  Racket include: ~a\n" (racket-runtime-include-dir runtime))
    (printf "  Racket lib: ~a\n" (racket-runtime-lib-dir runtime)))

  (define native?
    (case (system-type 'os)
      [(windows)
       (define tools (discover-windows-toolchain))
       (define msbuild? (windows-toolchain-msbuild tools))
       (define cl? (windows-toolchain-cl tools))
       (define lib? (windows-toolchain-lib tools))
       (printf "  MSBuild: ~a\n" (or msbuild? "not found"))
       (printf "  C++ compiler: ~a\n" (or cl? "not found"))
       (printf "  MSVC librarian: ~a\n" (or lib? "not found"))
       (printf "  UI: WinUI 3 / Windows App SDK 2.4\n")
       (and msbuild? cl? lib? runtime)]
      [(macosx)
       (define swift? (tool-status "Swift" "swift"))
       (define xcode? (tool-status "Xcode build" "xcodebuild"))
       (printf "  UI: SwiftUI / AppKit\n")
       (and swift? xcode? runtime)]
      [else
       (printf "  UI: unsupported (Rivet currently targets Windows and macOS)\n")
       #f]))

  (newline)
  (if (and raco? native?)
      (begin (printf "rivet: toolchain looks usable\n") 0)
      (begin (printf "rivet: toolchain is incomplete\n") 1)))
