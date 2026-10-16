#lang racket/base

(require json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "codegen.rkt"
         "project.rkt"
         "runtime.rkt"
         "windows-tools.rkt")

(provide doctor-report
         doctor-remediations
         run-doctor
         installed-rivet-release-version
         update-api-contract-violations
         repository-pin-findings
         release-doctor-report
         run-release-doctor)

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
        'racketcs-static (path-string (racket-runtime-racketcs-static runtime))
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

(define (command-success? executable . args)
  (and executable
       (parameterize ([current-output-port (open-output-nowhere)]
                      [current-error-port (open-output-nowhere)])
         (apply system* executable args))))

(define (linux-tools-report)
  (define pkg-config (find-executable-path "pkg-config"))
  (hash 'cmake (executable-string "cmake")
        'pkg-config (path-string pkg-config)
        'c++ (or (executable-string "c++")
                 (executable-string "g++")
                 (executable-string "clang++"))
        'ldd (executable-string "ldd")
        'gtk4 (command-success? pkg-config "--atleast-version=4.10" "gtk4")))

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
      [(unix)
       (define report (linux-tools-report))
       (values #t
               "GTK4"
               report
               (and (hash-ref report 'cmake)
                    (hash-ref report 'pkg-config)
                    (hash-ref report 'c++)
                    (hash-ref report 'ldd)
                    (hash-ref report 'gtk4)))]
      [else
       (values #f "unsupported" (hash) #f)]))

  (define usable? (and supported? racket-exe raco runtime essential-tools? #t))
  (define project (find-project))
  (define project-readiness
    (and project
         (let* ([baseline (project-path project "rivet-schema.json")]
                [configured? (file-exists? baseline)])
           (hash 'root (path-string (rivet-project-root project))
                 'schema-baseline-configured configured?))))
  (define warnings
    (if (and project-readiness
             (not (hash-ref project-readiness 'schema-baseline-configured)))
        (list
         (hash 'code "missing-schema-baseline"
               'severity "warning"
               'message "The project has no committed rivet-schema.json compatibility baseline."
               'remediation "Run `raco rivet schema --output rivet-schema.json`, review and commit it, then add `raco rivet schema check rivet-schema.json --json` to CI."))
        '()))
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
        'project-readiness project-readiness
        'warnings warnings
        'tools tools))

(define (missing-tool? tools key)
  (not (hash-ref tools key #f)))

(define (doctor-remediations report)
  (define fixes '())
  (define (add! title detail)
    (set! fixes (cons (cons title detail) fixes)))

  (unless (hash-ref report 'supported)
    (add! "Unsupported host platform"
          "Rivet builds first-party hosts on Windows, macOS, and Linux. Use one of those systems for `raco rivet dev`, `build`, and `package`."))

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

  (for ([warning (in-list (hash-ref report 'warnings '()))])
    (add! (hash-ref warning 'message)
          (hash-ref warning 'remediation)))

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
    [(unix)
     (define tools (hash-ref report 'tools))
     (when (or (missing-tool? tools 'cmake)
               (missing-tool? tools 'pkg-config)
               (missing-tool? tools 'c++)
               (missing-tool? tools 'ldd)
               (not (hash-ref tools 'gtk4 #f)))
       (add! "Install the Linux native toolchain"
             "Install CMake, pkg-config, a C++20 compiler, GTK 4.10 or newer development files, zlib, LZ4, and curses. On Debian/Ubuntu: sudo apt install build-essential cmake pkg-config libgtk-4-dev zlib1g-dev liblz4-dev libncurses-dev."))]
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
       [(unix)
        (display-path "Racket CS static library" (hash-ref runtime 'racketcs-static))]
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
    [(unix)
     (display-path "CMake" (hash-ref tools 'cmake))
     (display-path "pkg-config" (hash-ref tools 'pkg-config))
     (display-path "C++ compiler" (hash-ref tools 'c++))
     (display-path "dependency audit (ldd)" (hash-ref tools 'ldd))
     (printf "  GTK4 development package: ~a\n"
             (if (hash-ref tools 'gtk4 #f) "found" "not found"))]
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
     (define readiness (hash-ref report 'project-readiness #f))
     (when readiness
       (printf "  schema baseline: ~a\n"
               (if (hash-ref readiness 'schema-baseline-configured)
                   "configured"
                   "missing")))
     (newline)
     (printf "rivet: toolchain ~a\n"
             (if (hash-ref report 'usable) "looks usable" "is incomplete"))
     (when (or (not (hash-ref report 'usable))
               (pair? (hash-ref report 'warnings '())))
       (display-remediations report))])
  (if (hash-ref report 'usable) 0 1))

;; ---- Release gate (issues #245 and #255) ----
;;
;; Four incident classes the toolchain previously caught only on user
;; machines: (1) generated client files edited by hand or regenerated
;; against a different manifest (stale version stamps, renamed APIs), (2)
;; host source calling rivet distribution functions with keywords the
;; installed rivet does not accept (the payback #:redirections class), and
;; (3) dependency pins with an empty ref (`URL#` silently resolves to the
;; default branch) or a tag that does not match the installed rivet release.
;; `raco rivet doctor --release` runs all of them as one command so release
;; CI can gate on the exit code.

(define (call-with-source-forms path visit)
  ;; Feeds every top-level form of a source file to visit, skipping the
  ;; leading #lang reader directive that plain `read` cannot parse. Reading
  ;; the rest as data is deliberate: release checks want every datum,
  ;; including quoted ones.
  (define (scan-forms! in)
    (let loop ()
      (define datum (with-handlers ([exn:fail? (lambda (_) eof)])
                      (read in)))
      (unless (eof-object? datum)
        (visit datum)
        (loop))))
  (call-with-input-file path
    (lambda (in)
      (define first-line (read-line in 'any))
      (if (and (string? first-line) (regexp-match? #px"^#lang\\b" first-line))
          (scan-forms! in)
          ;; First line is ordinary source: reopen and scan from the top.
          (call-with-input-file path scan-forms!)))))

(define (read-info-release-version info-path)
  (define found (box #f))
  (call-with-source-forms
   info-path
   (lambda (datum)
     (when (and (pair? datum)
                (= (length datum) 3)
                (eq? (car datum) 'define)
                (eq? (cadr datum) 'release-version))
       (set-box! found (caddr datum)))))
  (unbox found))

(define (installed-rivet-release-version)
  ;; Returns #f when rivet itself is not installed as a collection (the
  ;; packaged CLI copies omit it); callers treat #f as "cannot check".
  ;; collection-file-path resolves a sub-collection directory, so the
  ;; package root that owns the release-version declaration is one level up.
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define collection-info (collection-file-path "info.rkt" "rivet"))
    (define root-info
      (simplify-path
       (build-path (path-only collection-info) 'up "info.rkt")))
    (and (file-exists? root-info) (read-info-release-version root-info))))

;; The distribution API surface is intentionally small, but hosts call it
;; from hand-written Racket where a stale keyword is a silent runtime failure
;; in the shipped app (five payback releases shipped with a keyword the
;; updater never accepted). Reading the installed function's own keyword
;; contract with procedure-keywords keeps this check honest across rivet
;; versions instead of duplicating the contract as literals here.
(define update-api-names
  '(fetch-update-manifest select-update download-update fetch-sibling-asset))

(define (update-api-procedures)
  (for/hasheq ([name (in-list update-api-names)])
    (values name (dynamic-require 'rivet/distribution name))))

(define (collect-files! root excluded-names extension-regex)
  ;; Hand-rolled pruning walk: find-files' predicate cannot skip whole
  ;; subtrees, and generated trees, build output, and vendored copies are
  ;; owned by rivet, not the host, so pruning them matters.
  (define files '())
  (let walk! ([dir root])
    (for ([entry (in-list (directory-list dir #:build? #t))])
      (cond
        [(directory-exists? entry)
         (unless (member (path->string (last (explode-path entry))) excluded-names)
           (walk! entry))]
        [(and extension-regex
              (regexp-match? extension-regex (path->string entry)))
         (set! files (cons entry files))])))
  (reverse files))

(define (source-files-under root)
  (collect-files! root
                  '(".git" ".rivet" "compiled" "dist" "node_modules" "stage")
                  #rx"[.]rkt$"))

(define pin-regex #px"rivet\\.git#([A-Za-z0-9._-]*)")

(define (text-files-under root)
  (collect-files! root
                  '(".git" ".rivet" "compiled" "dist" "node_modules" "stage")
                  #rx"[.](yml|yaml|md|rkt|rktd)$"))

(define (walk-datum! datum visit)
  (cond
    [(pair? datum)
     (visit datum)
     (let loop ([rest datum])
       (unless (null? rest)
         (walk-datum! (car rest) visit)
         (walk-datum! (cdr rest) visit)))]
    [(vector? datum)
     (for ([item (in-vector datum)]) (walk-datum! item visit))]
    [(box? datum) (walk-datum! (unbox datum) visit)]
    [(hash? datum)
     (for ([(key value) (in-hash datum)])
       (walk-datum! key visit)
       (walk-datum! value visit))]
    [else (void)]))

(define (update-api-contract-violations procedures path)
  ;; Returns a list of finding strings for one source file. Quoted data is
  ;; scanned too: a keyword-shaped datum inside a quoted form is never a
  ;; legitimate updater call, so flagging it fails safe rather than silent.
  (define violations '())
  (define (visit form)
    (when (pair? form)
      (define head (car form))
      (when (and (symbol? head) (hash-has-key? procedures head))
        (define proc (hash-ref procedures head))
        (define-values (_required allowed) (procedure-keywords proc))
        (for ([item (in-list (cdr form))] #:when (keyword? item))
          (unless (memq item allowed)
            (set! violations
                  (cons (format "~a: ~a does not accept ~a (installed rivet accepts ~a)"
                                path head item
                                (if (null? allowed)
                                    "no keywords"
                                    (string-join (map (lambda (kw) (format "~a" kw)) allowed) ", ")))
                        violations)))))))
  (call-with-source-forms
   path
   (lambda (datum) (walk-datum! datum visit)))
  (reverse violations))

(define (scan-rkt-call-keywords! root)
  (define procedures (update-api-procedures))
  (append*
   (for/list ([path (in-list (source-files-under root))])
     (update-api-contract-violations procedures path))))

(define (repository-pin-findings root installed-version)
  ;; Empty refs are the autarx v0.4.1 incident: `URL#` resolves to the
  ;; default branch, so CI ran a moving rivet while the release believed it
  ;; was pinned. Tag-shaped refs must name the installed release; commit
  ;; SHAs cannot be compared and are accepted as-is.
  (define expected-tag (and installed-version (string-append "v" installed-version)))
  (define findings '())
  (for ([path (in-list (text-files-under root))])
    (define text
      (with-handlers ([exn:fail? (lambda (_) "")])
        (file->string path)))
    (for ([pin-match (in-list (regexp-match* pin-regex text #:match-select cdr))])
      (define ref (list-ref pin-match 0))
      (cond
        [(string=? ref "")
         (set! findings
               (cons (format "~a: dependency pin `rivet.git#` has an empty ref and silently tracks the default branch; pin a tag or commit SHA"
                             path)
                     findings))]
        [(and expected-tag
              (regexp-match? #rx"^v[0-9]" ref)
              (not (string=? ref expected-tag)))
         (set! findings
               (cons (format "~a: dependency pin `rivet.git#~a` does not match the installed rivet release ~a"
                             path ref installed-version)
                     findings))])))
  (reverse findings))

(define (release-check name thunk)
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (hash 'name name 'status "fail" 'detail (exn-message error)))])
    (define detail (thunk))
    (if detail
        (hash 'name name 'status "fail" 'detail detail)
        (hash 'name name 'status "pass" 'detail #f))))

(define (release-doctor-report project)
  (define root (rivet-project-root project))
  (define installed-version (installed-rivet-release-version))
  (define checks
    (list
     ;; Freshness gate: regenerate in memory and compare, which also proves
     ;; every generated version/build stamp equals the rivet.rktd manifest.
     (release-check
      "generated clients are fresh"
      (lambda ()
        (define result (check-generated-clients project))
        (define stale (hash-ref result 'stale))
        (define missing (hash-ref result 'missing))
        (and (or (pair? stale) (pair? missing))
             (string-append
              (if (pair? stale)
                  (format "~a generated file~a differ~a from a fresh regeneration (hand-edited or stale version stamp); run `raco rivet generate`"
                          (length stale)
                          (if (= (length stale) 1) "" "s")
                          (if (= (length stale) 1) "s" ""))
                  "")
              (if (and (pair? stale) (pair? missing)) "; " "")
              (if (pair? missing)
                  (format "~a generated file~a missing; run `raco rivet generate`"
                          (length missing)
                          (if (= (length missing) 1) "" "s"))
                  "")))))
     (release-check
      "schema baseline exists and is compatible"
      (lambda ()
        (define baseline (project-path project "rivet-schema.json"))
        (cond
          [(not (file-exists? baseline))
           "the project has no committed rivet-schema.json baseline; run `raco rivet schema --output rivet-schema.json` and commit it"]
          [else
           (define report (check-schema-compatibility! project baseline))
           (and (not (hash-ref report 'compatible))
                (string-append
                 "the backend schema has breaking changes against the committed baseline: "
                 (string-join
                  (for/list ([item (in-list (hash-ref report 'breaking-changes))])
                    (hash-ref item 'message))
                  "; ")))])))
     (release-check
      "host sources call the update API with accepted keywords"
      (lambda ()
        (define violations (scan-rkt-call-keywords! root))
        (and (pair? violations) (string-join violations "; "))))
     (release-check
      "dependency pins are non-empty and match the installed release"
      (lambda ()
        (define findings (repository-pin-findings root installed-version))
        (and (pair? findings) (string-join findings "; "))))
     (release-check
      "installed rivet release is discoverable"
      (lambda ()
        (and (not installed-version)
             "could not read the installed rivet package's release version; install rivet as a package (raco pkg install) before releasing")))))
  (hash 'checks checks
        'failed (length (filter (lambda (check) (string=? (hash-ref check 'status) "fail")) checks))))

(define (display-release-doctor report)
  (printf "Rivet release doctor\n\n")
  (for ([check (in-list (hash-ref report 'checks))])
    (printf "  ~a ~a~a\n"
            (if (string=? (hash-ref check 'status) "pass") "ok  " "FAIL")
            (hash-ref check 'name)
            (let ([detail (hash-ref check 'detail)])
              (if detail (format "\n      ~a" detail) ""))))
  (newline)
  (printf "rivet: release gate ~a\n"
          (if (zero? (hash-ref report 'failed)) "passed" "failed")))

(define (run-release-doctor)
  (define project
    (or (find-project)
        (error 'rivet "no rivet.rktd found in this directory or its parents")))
  (define report (release-doctor-report project))
  (display-release-doctor report)
  (if (zero? (hash-ref report 'failed)) 0 1))
