#lang racket/base

(require json
         racket/path
         "runtime.rkt"
         "windows-tools.rkt")

(provide doctor-report
         doctor-remediations
         run-doctor)

(define (path-string value)
  (and value (path->string value)))

(define (executable-string name)
  (path-string (find-executable-path name)))

(define (runtime->report runtime)
  (hash 'version (racket-runtime-version runtime)
        'include-dir (path-string (racket-runtime-include-dir runtime))
        'lib-dir (path-string (racket-runtime-lib-dir runtime))
        'dll-dir (path-string (racket-runtime-dll-dir runtime))
        'petite-boot (path-string (racket-runtime-petite-boot runtime))
        'scheme-boot (path-string (racket-runtime-scheme-boot runtime))
        'racket-boot (path-string (racket-runtime-racket-boot runtime))
        'racketcs-dll (path-string (racket-runtime-racketcs-dll runtime))
        'racketcs-def (path-string (racket-runtime-racketcs-def runtime))
        'racket-framework (path-string (racket-runtime-racket-framework runtime))))

(define (windows-tools-report tools)
  (hash 'msbuild (path-string (windows-toolchain-msbuild tools))
        'cl (path-string (windows-toolchain-cl tools))
        'lib (path-string (windows-toolchain-lib tools))
        'dumpbin (path-string (windows-toolchain-dumpbin tools))
        'signtool (path-string (windows-toolchain-signtool tools))))

(define (macos-tools-report)
  (hash 'swift (executable-string "swift")
        'xcodebuild (executable-string "xcodebuild")
        'otool (executable-string "otool")
        'codesign (executable-string "codesign")
        'plutil (executable-string "plutil")
        'xcrun (executable-string "xcrun")
        'spctl (executable-string "spctl")))

(define (doctor-report)
  (define os (system-type 'os))
  (define arch (system-type 'arch))
  (define racket-exe (executable-string "racket"))
  (define raco (executable-string "raco"))

  (define runtime-error #f)
  (define runtime
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! runtime-error (exn-message e))
                       #f)])
      (discover-racket-runtime)))

  (define-values (supported? ui tools essential-tools?)
    (case os
      [(windows)
       (define discovered (discover-windows-toolchain))
       (define report (windows-tools-report discovered))
       (values #t
               "WinUI 3 / Windows App SDK 2.4"
               report
               (and (hash-ref report 'msbuild)
                    (hash-ref report 'cl)
                    (hash-ref report 'lib)
                    (hash-ref report 'dumpbin)))]
      [(macosx)
       (define report (macos-tools-report))
       (values #t
               "SwiftUI / AppKit"
               report
               (and (hash-ref report 'swift)
                    (hash-ref report 'xcodebuild)
                    (hash-ref report 'otool)
                    (hash-ref report 'codesign)
                    (hash-ref report 'plutil)))]
      [else
       (values #f "unsupported" (hash) #f)]))

  (define usable? (and supported? racket-exe raco runtime essential-tools? #t))
  (hash 'os (symbol->string os)
        'architecture (format "~a" arch)
        'supported supported?
        'usable usable?
        'ui ui
        'racket-executable racket-exe
        'raco raco
        'racket-version (version)
        'runtime (and runtime (runtime->report runtime))
        'runtime-error runtime-error
        'tools tools))

(define (missing-tool? tools key)
  (not (hash-ref tools key #f)))

(define (doctor-remediations report)
  (define fixes '())
  (define (add! title detail)
    (set! fixes (cons (cons title detail) fixes)))

  (unless (hash-ref report 'supported)
    (add! "Unsupported host platform"
          "Rivet currently builds first-party hosts on Windows and macOS. Use one of those systems for `raco rivet dev`, `build`, and `package`."))

  (unless (hash-ref report 'racket-executable)
    (add! "Expose Racket CS on PATH"
          "Add the `bin` directory of the Racket CS installation running Rivet to PATH so `racket` is discoverable from a fresh terminal."))
  (unless (hash-ref report 'raco)
    (add! "Expose raco on PATH"
          "Use the `raco` executable from the same Racket installation that will run Rivet."))
  (unless (hash-ref report 'runtime)
    (add! "Repair the Racket CS runtime"
          (string-append
           "Rivet could not discover the complete embedded runtime. Install a full Racket CS distribution and reinstall Rivet with that installation's `raco`."
           (let ([reason (hash-ref report 'runtime-error #f)])
             (if reason (format " Discovery error: ~a" reason) "")))))

  (case (string->symbol (hash-ref report 'os))
    [(windows)
     (define tools (hash-ref report 'tools))
     (when (or (missing-tool? tools 'msbuild)
               (missing-tool? tools 'cl)
               (missing-tool? tools 'lib)
               (missing-tool? tools 'dumpbin))
       (add! "Install the Windows C++ toolchain"
             "Open Visual Studio Installer and install Visual Studio 2022 (or Build Tools 2022) with the `Desktop development with C++` workload and a Windows 10/11 SDK. Rivet restores its Windows App SDK package during the build. Then open a new terminal and rerun `raco rivet doctor`."))]
    [(macosx)
     (define tools (hash-ref report 'tools))
     (when (or (missing-tool? tools 'swift)
               (missing-tool? tools 'xcodebuild)
               (missing-tool? tools 'otool)
               (missing-tool? tools 'codesign)
               (missing-tool? tools 'plutil))
       (add! "Install the Apple developer toolchain"
             "Run `xcode-select --install`. If `xcodebuild` is still missing, install Xcode and select it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then rerun `raco rivet doctor`."))]
    [else (void)])

  (reverse fixes))

(define (display-path label value [optional-note #f])
  (printf "  ~a: ~a~a\n"
          label
          (or value "not found")
          (if (and (not value) optional-note)
              (string-append " (" optional-note ")")
              "")))

(define (display-runtime report)
  (define runtime (hash-ref report 'runtime))
  (cond
    [runtime
     (display-path "Racket include" (hash-ref runtime 'include-dir))
     (display-path "Racket lib" (hash-ref runtime 'lib-dir))
     (display-path "Racket DLL dir" (hash-ref runtime 'dll-dir))
     (display-path "petite.boot" (hash-ref runtime 'petite-boot))
     (display-path "scheme.boot" (hash-ref runtime 'scheme-boot))
     (display-path "racket.boot" (hash-ref runtime 'racket-boot))
     (case (string->symbol (hash-ref report 'os))
       [(windows)
        (display-path "Racket CS DLL" (hash-ref runtime 'racketcs-dll))
        (display-path "Racket CS DEF" (hash-ref runtime 'racketcs-def))]
       [(macosx)
        (display-path "Racket.framework" (hash-ref runtime 'racket-framework))]
       [else (void)])]
    [else
     (printf "  Racket runtime: error — ~a\n"
             (or (hash-ref report 'runtime-error) "unknown error"))]))

(define (display-tools report)
  (define os (string->symbol (hash-ref report 'os)))
  (define tools (hash-ref report 'tools))
  (case os
    [(windows)
     (display-path "MSBuild" (hash-ref tools 'msbuild))
     (display-path "C++ compiler" (hash-ref tools 'cl))
     (display-path "MSVC librarian" (hash-ref tools 'lib))
     (display-path "dependency audit (dumpbin)" (hash-ref tools 'dumpbin))
     (display-path "production signing (signtool)"
                   (hash-ref tools 'signtool)
                   "development packaging is still available")]
    [(macosx)
     (display-path "Swift" (hash-ref tools 'swift))
     (display-path "Xcode build" (hash-ref tools 'xcodebuild))
     (display-path "otool" (hash-ref tools 'otool))
     (display-path "codesign" (hash-ref tools 'codesign))
     (display-path "plist verification (plutil)" (hash-ref tools 'plutil))
     (display-path "production notarization (xcrun)"
                   (hash-ref tools 'xcrun)
                   "development packaging is still available")
     (display-path "Gatekeeper assessment (spctl)"
                   (hash-ref tools 'spctl)
                   "development packaging is still available")]
    [else (void)]))

(define (display-remediations report)
  (define fixes (doctor-remediations report))
  (unless (null? fixes)
    (newline)
    (displayln "Fix next:")
    (for ([fix (in-list fixes)] [index (in-naturals 1)])
      (printf "  ~a. ~a\n     ~a\n" index (car fix) (cdr fix)))))

(define (run-doctor #:json? [json? #f])
  (define report (doctor-report))
  (cond
    [json?
     (write-json report)
     (newline)]
    [else
     (printf "Rivet doctor\n\n")
     (printf "  OS: ~a\n" (hash-ref report 'os))
     (printf "  architecture: ~a\n" (hash-ref report 'architecture))
     (printf "  Racket: ~a\n" (hash-ref report 'racket-version))
     (display-path "Racket executable" (hash-ref report 'racket-executable))
     (display-path "raco" (hash-ref report 'raco))
     (display-runtime report)
     (display-tools report)
     (printf "  UI: ~a\n" (hash-ref report 'ui))
     (newline)
     (printf "rivet: toolchain ~a\n"
             (if (hash-ref report 'usable) "looks usable" "is incomplete"))
     (unless (hash-ref report 'usable)
       (display-remediations report))])
  (if (hash-ref report 'usable) 0 1))
