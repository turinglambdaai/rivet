#lang racket/base

(require json
         racket/file
         racket/path
         "project.rkt")

(provide project-report
         run-inspect)

(define contract-version 1)

(define (path-string path)
  (path->string (simplify-path path #t)))

(define (source-report project relative kind)
  (define absolute (project-path project relative))
  (hash 'path
        relative
        'absolute
        (path-string absolute)
        'kind
        (symbol->string kind)
        'exists
        (if (eq? kind 'directory)
            (directory-exists? absolute)
            (file-exists? absolute))))

(define (target name status ui source)
  (hash 'name name 'status status 'ui ui 'source source))

(define (action name command mutates)
  (hash 'name name 'command command 'mutates mutates))

(define (sourcing-option rank kind use-when boundary)
  (hash 'rank rank 'kind kind 'use-when use-when 'boundary boundary))

;; Keep this guidance structured and concise: generated AGENTS.md contains the
;; working rules, while docs/agent-native.md explains the trade-offs. Editors
;; and coding agents should not have to scrape prose to discover Rivet's
;; preferred escape hatches when a capability is missing from Racket itself.
(define capability-sourcing
  (hash
   'version
   1
   'policy
   "Choose the narrowest maintainable boundary; ecosystem size alone is not a reason to leave Racket."
   'discovery
   (list (hash 'purpose "installed documentation" 'command "raco docs <term>")
         (hash 'purpose "installed packages" 'command "raco pkg show")
         (hash 'purpose "catalog inventory" 'command "raco pkg catalog-show --all --only-names")
         (hash 'purpose
               "package metadata and modules"
               'command
               "raco pkg catalog-show --modules <package>"))
   'decision-order
   (list
    (sourcing-option
     1
     "racket-library"
     "A maintained Racket 9.0+ package or built-in module satisfies the capability."
     "Keep portable application logic in app/ and declare/check the exact package dependency.")
    (sourcing-option
     2
     "native-host"
     "The capability is UI, lifecycle, accessibility, notification, device, or another platform-owned service."
     "Implement it in windows/, macos-host/, or linux/ and cross the generated RVT1 API only when shared logic needs it.")
    (sourcing-option
     3
     "ffi"
     "A stable C ABI needs frequent, low-latency, in-process calls."
     "Hide ffi/unsafe behind a small safe Racket module; specify ownership, callbacks, threads, ABI/version checks, and packaged native libraries.")
    (sourcing-option
     4
     "cli"
     "A mature executable performs coarse-grained bounded work and process isolation is useful."
     "Use subprocess or system* with an executable plus argv, never a constructed shell command; enforce timeouts, output limits, exit checks, version probes, cancellation, packaging, and licensing.")
    (sourcing-option
     5
     "sidecar"
     "A persistent tool/runtime, streaming workload, unstable ABI, or crash isolation makes per-call CLI startup or in-process FFI unsuitable."
     "Own local authentication, version negotiation, bounded messages, lifecycle, crash recovery, shutdown, packaging, and offline behavior.")
    (sourcing-option
     6
     "implement"
     "The missing capability is small, security-critical, or cheaper to own than its dependency and distribution surface."
     "Document the rejected alternatives and add conformance tests before maintaining a new implementation."))
   'required-checks
   (list "license and redistribution"
         "Racket 9.0 CS compatibility"
         "Windows/macOS/Linux and required architectures"
         "maintenance and upstream security posture"
         "deterministic installation and version pinning"
         "timeouts, cancellation, resource bounds, and failure behavior"
         "packaged-artifact dependency closure"
         "clean-machine and offline-runtime verification")
   'documentation
   (hash 'installed "raco docs rivet"
         'source "https://github.com/turinglambdaai/rivet/blob/main/docs/agent-native.md#capability-sourcing")))

(define (project-report project)
  (define root (rivet-project-root project))
  (define backend (project-ref project 'backend))
  (hash 'contract-version
        contract-version
        'product
        "Rivet"
        'principles
        (list "Human-first" "Agent-native" "Local by design")
        'project
        (hash 'root
              (path-string root)
              'config
              (path-string (project-path project "rivet.rktd"))
              'name
              (project-name project)
              'display-name
              (project-display-name project)
              'publisher
              (project-publisher project)
              'version
              (project-version project)
              'build
              (project-build project)
              'identifier
              (project-identifier project)
              'release-channel
              (symbol->string (project-release-channel project))
              'protocol
              (project-ref project 'protocol))
        'backend
        (hash 'source
              (source-report project backend 'file)
              'module
              (project-ref project 'module)
              'entry
              (project-ref project 'entry))
        'schema
        (hash 'baseline (source-report project "rivet-schema.json" 'file)
              'format "rivet-schema"
              'format-version 1)
        'generated-clients
        (hash 'swift
              (source-report project "macos-host/Sources/RivetHost/GeneratedBackend.swift" 'file)
              'cpp-windows
              (source-report project "windows/GeneratedBackend.hpp" 'file)
              'cpp-linux
              (source-report project "linux/GeneratedBackend.hpp" 'file)
              'kotlin
              (source-report project ".rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt" 'file))
        'capability-sourcing
        capability-sourcing
        'edit-points
        (hash 'shared-logic
              (list (source-report project backend 'file))
              'windows-ui
              (list (source-report project "windows/MainWindow.xaml" 'file)
                    (source-report project "windows/MainWindow.xaml.cpp" 'file))
              'macos-ui
              (list (source-report project "macos-host/Sources/RivetHost/ContentView.swift" 'file)
                    (source-report project "macos-host/Sources/RivetHost/RivetHostApp.swift" 'file))
              'linux-ui
              (list (source-report project "linux/src/main.cpp" 'file))
              'configuration
              (list (source-report project "rivet.rktd" 'file)
                    (source-report project "rivet-schema.json" 'file)))
        'targets
        (list (target "windows" "production-target" "WinUI 3 / C++/WinRT" "windows")
              (target "macos" "production-target" "SwiftUI / AppKit" "macos-host")
              (target "linux" "developer-preview" "GTK4" "linux")
              (target "ios" "foundation" "SwiftUI" #f)
              (target "ipados" "foundation" "SwiftUI" #f)
              (target "watchos" "typed-companion-foundation" "SwiftUI" #f)
              (target "android" "protocol-runtime-foundation" "Jetpack Compose" #f))
        'generated-paths
        (for/list ([relative (in-list '(".rivet" "build" "dist"))])
          (source-report project relative 'directory))
        'commands
        (list (action "inspect" "raco rivet inspect --json" #f)
              (action "diagnose" "raco rivet doctor --json" #f)
              (action "inspect-schema" "raco rivet schema --json" #f)
              (action "save-schema-baseline"
                      "raco rivet schema --output rivet-schema.json"
                      #t)
              (action "check-schema-compatibility"
                      "raco rivet schema check rivet-schema.json --json"
                      #f)
              (action "build" "raco rivet build" #t)
              (action "run" "raco rivet dev" #t)
              (action "package" "raco rivet package" #t)
              (action "verify" "raco rivet verify" #f)
              (action "clean-generated" "raco rivet clean" #t))))

(define (display-report report)
  (define project (hash-ref report 'project))
  (printf "Rivet project: ~a (~a)\n" (hash-ref project 'display-name) (hash-ref project 'identifier))
  (printf "  root: ~a\n" (hash-ref project 'root))
  (printf "  version: ~a (build ~a)\n" (hash-ref project 'version) (hash-ref project 'build))
  (displayln "  edit points:")
  (define edits (hash-ref report 'edit-points))
  (for ([group (in-list '(shared-logic windows-ui macos-ui linux-ui configuration))])
    (for ([entry (in-list (hash-ref edits group))])
      (printf "    ~a: ~a [~a]\n"
              group
              (hash-ref entry 'path)
              (if (hash-ref entry 'exists) "present" "missing"))))
  (displayln "  next:")
  (displayln "    raco rivet doctor --json")
  (displayln "    raco rivet dev")
  (displayln "  missing a capability:")
  (for ([option (in-list (hash-ref (hash-ref report 'capability-sourcing) 'decision-order))])
    (printf "    ~a. ~a: ~a\n"
            (hash-ref option 'rank)
            (hash-ref option 'kind)
            (hash-ref option 'use-when))))

(define (run-inspect project #:json? [json? #f])
  (define report (project-report project))
  (if json?
      (begin
        (write-json report)
        (newline))
      (display-report report))
  0)
