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
  (hash 'path relative
        'absolute (path-string absolute)
        'kind (symbol->string kind)
        'exists (if (eq? kind 'directory)
                    (directory-exists? absolute)
                    (file-exists? absolute))))

(define (target name status ui source)
  (hash 'name name
        'status status
        'ui ui
        'source source))

(define (action name command mutates)
  (hash 'name name
        'command command
        'mutates mutates))

(define (project-report project)
  (define root (rivet-project-root project))
  (define backend (project-ref project 'backend))
  (hash
   'contract-version contract-version
   'product "Rivet"
   'principles (list "Human-first" "Agent-native" "Local by design")
   'project
   (hash 'root (path-string root)
         'config (path-string (project-path project "rivet.rktd"))
         'name (project-name project)
         'display-name (project-display-name project)
         'version (project-version project)
         'build (project-build project)
         'identifier (project-identifier project)
         'release-channel (symbol->string (project-release-channel project))
         'protocol (project-ref project 'protocol))
   'backend
   (hash 'source (source-report project backend 'file)
         'module (project-ref project 'module)
         'entry (project-ref project 'entry))
   'edit-points
   (hash 'shared-logic (list (source-report project backend 'file))
         'windows-ui
         (list (source-report project "windows/MainWindow.xaml" 'file)
               (source-report project "windows/MainWindow.xaml.cpp" 'file))
         'macos-ui
         (list (source-report project "macos-host/Sources/RivetHost/ContentView.swift" 'file)
               (source-report project "macos-host/Sources/RivetHost/RivetHostApp.swift" 'file))
         'linux-ui
         (list (source-report project "linux/src/main.cpp" 'file))
         'configuration
         (list (source-report project "rivet.rktd" 'file)))
   'targets
   (list
    (target "windows" "production-target" "WinUI 3 / C++/WinRT" "windows")
    (target "macos" "production-target" "SwiftUI / AppKit" "macos-host")
    (target "linux" "developer-preview" "GTK4" "linux")
    (target "ios" "foundation" "SwiftUI" #f)
    (target "ipados" "foundation" "SwiftUI" #f)
    (target "watchos" "typed-companion-foundation" "SwiftUI" #f)
    (target "android" "protocol-runtime-foundation" "Jetpack Compose" #f)
    (target "wearos" "companion-foundation" "Compose for Wear OS" #f))
   'generated-paths
   (for/list ([relative (in-list '(".rivet" "build" "dist"))])
     (source-report project relative 'directory))
   'commands
   (list
    (action "inspect" "raco rivet inspect --json" #f)
    (action "diagnose" "raco rivet doctor --json" #f)
    (action "build" "raco rivet build" #t)
    (action "run" "raco rivet dev" #t)
    (action "package" "raco rivet package" #t)
    (action "verify" "raco rivet verify" #f)
    (action "clean-generated" "raco rivet clean" #t))))

(define (display-report report)
  (define project (hash-ref report 'project))
  (printf "Rivet project: ~a (~a)\n"
          (hash-ref project 'display-name)
          (hash-ref project 'identifier))
  (printf "  root: ~a\n" (hash-ref project 'root))
  (printf "  version: ~a (build ~a)\n"
          (hash-ref project 'version)
          (hash-ref project 'build))
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
  (displayln "    raco rivet dev"))

(define (run-inspect project #:json? [json? #f])
  (define report (project-report project))
  (if json?
      (begin (write-json report) (newline))
      (display-report report))
  0)
