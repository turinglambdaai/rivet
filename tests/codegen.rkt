#lang racket/base

(require json
         rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         "../rivet-cli/codegen.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-codegen-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "demo" temp-root))
    (define app-xaml
      (file->string (build-path project-root "windows" "App.xaml")))
    (define app-cpp
      (file->string (build-path project-root "windows" "App.xaml.cpp")))
    (define windows-project
      (file->string (build-path project-root "windows" "RivetHost.vcxproj")))
    (define windows-main-header
      (file->string (build-path project-root "windows" "MainWindow.xaml.h")))
    (define windows-main-source
      (file->string (build-path project-root "windows" "MainWindow.xaml.cpp")))
    (define macos-app-source
      (file->string (build-path project-root "macos-host" "Sources" "RivetHost" "RivetHostApp.swift")))
    (define macos-package
      (file->string (build-path project-root "macos-host" "Package.swift")))
    (define linux-cmake
      (file->string (build-path project-root "linux" "CMakeLists.txt")))
    (define linux-main
      (file->string (build-path project-root "linux" "src" "main.cpp")))
    (define project-config
      (file->string (build-path project-root "rivet.rktd")))
    (define generated-ignore
      (file->string (build-path project-root ".gitignore")))
    (define agent-contract
      (file->string (build-path project-root "AGENTS.md")))
    (check-true (regexp-match? #rx"XamlControlsResources" app-xaml))
    (check-true
     (regexp-match? #rx"Windows::Foundation::IInspectable" app-cpp))
    (check-true (regexp-match? #rx"/utf-8" windows-project))
    (check-true (regexp-match? #rx"RIVET_WINDOWS_MIN_VERSION" windows-project))
    (check-true
     (string-contains? windows-project "platform\\windows\\system"))
    (check-true
     (regexp-match? #rx"rivet::system::NativeWindowHandle" windows-main-header))
    (check-true (regexp-match? #rx"HWND WindowHandle" windows-main-header))
    (check-true
     (regexp-match? #rx"rivet::system::InstallShutdownHook" windows-main-source))
    (check-true (regexp-match? #rx"StopBackendOrderly" windows-main-header))
    (check-true
     (regexp-match? #rx"applicationShouldTerminate" macos-app-source))
    (check-true
     (regexp-match? #rx"orderlyShutdown" macos-app-source))
    (check-false
     (regexp-match? #rx"<WindowsTargetPlatformMinVersion>10\\.0\\.19041\\.0"
                    windows-project))
    (check-true (regexp-match? #rx"RIVET_MACOS_MIN_VERSION" macos-package))
    (check-true (regexp-match? #rx"RivetDevice" macos-package))
    (check-true (regexp-match? #rx"platform/linux/runtime" linux-cmake))
    (check-true (regexp-match? #rx"platform/linux/theme/theme[.]cpp" linux-cmake))
    (check-true (regexp-match? #rx"rivet::linux_ui::ApplyTheme" linux-main))
    (check-true
     (regexp-match?
      #px"(?s:g_state[.]backend = std::move[(]backend[)];.*InstallShutdownHook)"
      linux-main)
     "the generated Linux host must install its signal hook after backend startup")
    (for ([generated-path (in-list '("windows/Generated Files/"
                                     "windows/obj/"
                                     "windows/RivetHost/"
                                     "macos-host/.build/"))])
      (check-true (string-contains? generated-ignore generated-path)))
    (for ([generated-client (in-list '("windows/GeneratedBackend.hpp"
                                       "macos-host/Sources/RivetHost/GeneratedBackend.swift"
                                       "linux/GeneratedBackend.hpp"))])
      (check-true (string-contains? agent-contract generated-client)))
    (check-true
     (regexp-match? #rx"\\(macos-min-version \\. \"14\\.0\"\\)" project-config))
    (check-true
     (regexp-match? #rx"\\(windows-min-version \\. \"10\\.0\\.19041\\.0\"\\)"
                     project-config))
    (check-true (regexp-match? #rx"\\(device-rpcs \\. \\(\\)\\)" project-config))

    (define (write-backend! project-root content)
      (call-with-output-file
       (build-path project-root "app" "backend.rkt")
       #:exists 'truncate/replace
       (lambda (out) (display content out))))

    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)

(provide start)

(define-event progress : Int64)

(define-record User
  ([id : Int64]
   [display-name : String]
   [nickname : (Optional String)]))

;; Common domain names must not shadow Swift concurrency/stdlib types in the
;; application module. Generated schema values live under RivetTypes.
(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (increment [value Int64] : Int64)
  (add1 value))

(define-rpc (echo-user [user : User] : User)
  user)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )

    (define project (load-project project-root))
    (define schema (generate-clients! project))
    (check-equal? (length (first schema)) 3)
    (check-equal? (length (second schema)) 1)
    (check-equal? (length (third schema)) 1)

    (define swift
      (file->string
       (build-path project-root
                   "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")))
    (define cpp
      (file->string
       (build-path project-root "windows" "GeneratedBackend.hpp")))
    (define linux-cpp
      (file->string
       (build-path project-root "linux" "GeneratedBackend.hpp")))
    (define kotlin
      (file->string
       (build-path project-root
                   ".rivet" "generated" "kotlin" "dev" "rivet" "generated"
                   "GeneratedBackend.kt")))

    (check-true (regexp-match? #rx"public enum RivetTypes" swift))
    (check-true (regexp-match? #rx"    public struct User: Sendable" swift))
    (check-true (regexp-match? #rx"displayName = \"demo\"" swift))
    (check-true (regexp-match? #rx"version = \"0[.]1[.]0\"" swift))
    (check-true (regexp-match? #rx"build: Int64 = 1" swift))
    (check-true (regexp-match? #rx"identifier = \"dev[.]rivet[.]demo\"" swift))
    (check-true (regexp-match? #rx"releaseChannel = \"stable\"" swift))
    (check-false (regexp-match? #rx"import RivetDevice" swift))
    (check-false (regexp-match? #rx"registerGeneratedBackend" swift))
    (check-true (regexp-match? #rx"public let display_name: String" swift))
    (check-true (regexp-match? #rx"public let nickname: String\\?" swift))
    (check-true (regexp-match? #rx"func echo_user\\(user: RivetTypes.User\\) async throws -> RivetTypes.User" swift))
    (check-true (regexp-match? #rx"func greet\\(name: String\\)" swift))
    (check-true (regexp-match? #rx"func increment\\(value: Int64\\)" swift))
    (check-true (regexp-match? #rx"func get_counter\\(\\) async throws -> Int64" swift))
    (check-true (regexp-match? #rx"func set_counter\\(_ value: Int64\\)" swift))

    (check-true (regexp-match? #rx"struct User" cpp))
    (check-true (regexp-match? #rx"kDisplayName\\[\\] = \"demo\"" cpp))
    (check-true (regexp-match? #rx"kVersion\\[\\] = \"0[.]1[.]0\"" cpp))
    (check-true (regexp-match? #rx"kBuild = 1" cpp))
    (check-true (regexp-match? #rx"kIdentifier\\[\\] = \"dev[.]rivet[.]demo\"" cpp))
    (check-true (regexp-match? #rx"kReleaseChannel\\[\\] = \"stable\"" cpp))
    (check-true (regexp-match? #rx"std::string display_name;" cpp))
    (check-true (regexp-match? #rx"std::optional<std::string> nickname;" cpp))
    (check-true (regexp-match? #rx"std::future<User> echo_user\\(User user\\)" cpp))
    (check-true (regexp-match? #rx"std::future<std::string> greet" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> increment" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> get_counter\\(\\)" cpp))
    (check-true (regexp-match? #rx"std::future<std::int64_t> set_counter\\(std::int64_t value\\)" cpp))

    ;; Windows also gets typed, cancellable completion APIs with no blocking get().
    (check-true (regexp-match? #rx"struct Result" cpp))
    (check-true (regexp-match? #rx"std::uint64_t greet_async" cpp))
    (check-true (regexp-match? #rx"std::function<void\\(Result<std::string>\\)> completion" cpp))
    (check-true (regexp-match? #rx"std::uint64_t increment_async" cpp))
    (check-true (regexp-match? #rx"std::uint64_t get_counter_async" cpp))
    (check-true (regexp-match? #rx"std::uint64_t set_counter_async" cpp))
    (check-true (regexp-match? #rx"backend_\\.request_async" cpp))
    (check-true (regexp-match? #rx"backend_\\.get_state_async" cpp))
    (check-true (regexp-match? #rx"backend_\\.set_state_async" cpp))
    (check-true (regexp-match? #rx"struct ProgressEvent \\{ std::int64_t value; \\};" cpp))
    (check-true
     (regexp-match? #rx"rivet::linux_runtime::Backend& backend" linux-cpp))
    (check-true
     (regexp-match? #rx"rivet::linux_runtime::CallResult raw" linux-cpp))
    (check-false (regexp-match? #rx"rivet::windows" linux-cpp))

    ;; The typed Kotlin client targets the coroutine runtime. State accessors
    ;; are package-level extension functions, so the imports are load-bearing.
    (check-true (regexp-match? #rx"package dev.rivet.generated" kotlin))
    (check-true (regexp-match? #rx"displayName = \"demo\"" kotlin))
    (check-true (regexp-match? #rx"version = \"0[.]1[.]0\"" kotlin))
    (check-true (regexp-match? #rx"build: Long = 1L" kotlin))
    (check-true (regexp-match? #rx"identifier = \"dev[.]rivet[.]demo\"" kotlin))
    (check-true (regexp-match? #rx"releaseChannel = \"stable\"" kotlin))
    (check-true
     (regexp-match? #rx"import dev\\.rivet\\.runtime\\.RivetClient" kotlin))
    (check-true
     (regexp-match? #rx"import dev\\.rivet\\.runtime\\.getState" kotlin))
    (check-true
     (regexp-match? #rx"import dev\\.rivet\\.runtime\\.setState" kotlin))
    (check-true (regexp-match? #rx"data class User\\(" kotlin))
    (check-true (regexp-match? #rx"val display_name: String," kotlin))
    (check-true (regexp-match? #rx"val nickname: String\\?," kotlin))
    (check-true
     (regexp-match? #rx"suspend fun greet\\(name: String\\): String" kotlin))
    (check-true
     (regexp-match? #rx"suspend fun echo_user\\(user: User\\): User" kotlin))
    (check-true
     (regexp-match? #rx"suspend fun get_counter\\(\\): Long" kotlin))
    (check-true
     (regexp-match? #rx"suspend fun set_counter\\(value: Long\\): Long" kotlin))
    (check-true
     (regexp-match? #rx"client\\.getState\\(\"counter\"\\)" kotlin))
    (check-true
     (regexp-match? #rx"client\\.setState\\(\"counter\", encode_Int64\\(value\\)\\)" kotlin))
    (check-true
     (regexp-match? #rx"class RivetAPI\\(val client: RivetClient\\)" kotlin))
    (check-true (regexp-match? #rx"sealed interface RivetEvent" kotlin))
    (check-true
     (regexp-match? #rx"data class Progress\\(val value: Long\\) : RivetEvent" kotlin))
    (check-true
     (regexp-match? #rx"\"progress\" -> Progress\\(decode_Int64\\(value\\)\\)" kotlin))

    ;; A versioned snapshot is suitable for source control and CI. Additions are
    ;; compatible, while changing a published signature is reported and fails.
    (define baseline-path (build-path project-root "schema-baseline.json"))
    (check-equal? (write-schema-snapshot! project baseline-path) baseline-path)
    (define baseline
      (call-with-input-file baseline-path read-json))
    (check-equal? (hash-ref baseline 'format) "rivet-schema")
    (check-equal? (hash-ref baseline 'format-version) 1)
    (check-equal? (hash-ref baseline 'rvt-protocol) 1)
    (check-equal? (length (hash-ref baseline 'records)) 1)
    (check-equal?
     (map (lambda (entry) (hash-ref entry 'name)) (hash-ref baseline 'rpcs))
     '("echo-user" "greet" "increment"))
    ;; Enum support extends snapshot format v1 additively. A baseline written
    ;; by the pre-Enum v1 tool omitted the key and means an empty enum set.
    (define pre-enum-baseline-path
      (build-path project-root "pre-enum-schema-baseline.json"))
    (call-with-output-file pre-enum-baseline-path #:exists 'truncate/replace
      (lambda (out) (write-json (hash-remove baseline 'enums) out)))
    (check-true
     (hash-ref (check-schema-compatibility! project pre-enum-baseline-path)
               'compatible))

    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-event progress : Int64)
(define-record User
  ([id : Int64]
   [display-name : String]
   [nickname : (Optional String)]))
(define-state counter : Int64 0)
(define-rpc (greet [name String] : String) name)
(define-rpc (increment [value Int64] : Int64) (add1 value))
(define-rpc (echo-user [user : User] : User) user)
(define-rpc (health : Bool) #t)
(define (start in-fd out-fd) (serve-fds in-fd out-fd))
RKT
     )
    (define compatible-report
      (check-schema-compatibility! project baseline-path))
    (check-true (hash-ref compatible-report 'compatible))
    (check-equal? (length (hash-ref compatible-report 'compatible-additions)) 1)
    (check-equal? (hash-ref (first (hash-ref compatible-report 'compatible-additions))
                            'name)
                  "health")

    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-event progress : Int64)
(define-record User
  ([id : Int64]
   [display-name : String]
   [nickname : (Optional String)]))
(define-state counter : Int64 0)
(define-rpc (greet [name String] : Bytes) #"")
(define-rpc (increment [value Int64] : Int64) (add1 value))
(define-rpc (echo-user [user : User] : User) user)
(define (start in-fd out-fd) (serve-fds in-fd out-fd))
RKT
     )
    (define breaking-report
      (check-schema-compatibility! project baseline-path))
    (check-false (hash-ref breaking-report 'compatible))
    (check-equal? (length (hash-ref breaking-report 'breaking-changes)) 1)
    (check-equal? (hash-ref (first (hash-ref breaking-report 'breaking-changes))
                            'name)
                  "greet")

    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-event progress : Int64)
(define-record User
  ([display-name : String]
   [id : Int64]
   [nickname : (Optional String)]))
(define-state counter : Int64 0)
(define-rpc (greet [name String] : String) name)
(define-rpc (increment [value Int64] : Int64) (add1 value))
(define-rpc (echo-user [user : User] : User) user)
(define (start in-fd out-fd) (serve-fds in-fd out-fd))
RKT
     )
    (define reordered-record-report
      (check-schema-compatibility! project baseline-path))
    (check-false (hash-ref reordered-record-report 'compatible))
    (check-equal? (length (hash-ref reordered-record-report 'breaking-changes)) 1)
    (check-equal? (hash-ref (first (hash-ref reordered-record-report 'breaking-changes))
                            'name)
                  "User")

    ;; Named Enums use stable String wire values and native Swift/C++ enums.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-enum Role (admin member))
(define-rpc (echo-role [role : Role] : Role) role)
(define (start in-fd out-fd) (serve-fds in-fd out-fd))
RKT
     )
    (define enum-schema-result (generate-clients! project))
    (check-equal? (length enum-schema-result) 5)
    (check-equal? (length (fifth enum-schema-result)) 1)
    (define enum-swift
      (file->string
       (build-path project-root
                   "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")))
    (define enum-cpp
      (file->string (build-path project-root "windows" "GeneratedBackend.hpp")))
    (check-regexp-match #rx"public enum Role: String, Sendable" enum-swift)
    (check-regexp-match #rx"case admin = \"admin\"" enum-swift)
    (check-regexp-match #rx"func echo_role\\(role: RivetTypes.Role\\) async throws -> RivetTypes.Role" enum-swift)
    (check-regexp-match #rx"enum class Role \\{ admin, member \\};" enum-cpp)
    (check-regexp-match #rx"std::future<Role> echo_role\\(Role role\\)" enum-cpp)
    (define enum-kotlin
      (file->string
       (build-path project-root
                   ".rivet" "generated" "kotlin" "dev" "rivet" "generated"
                   "GeneratedBackend.kt")))
    (check-regexp-match #rx"enum class Role\\(val wireName: String\\)" enum-kotlin)
    (check-regexp-match #rx"admin\\(\"admin\"\\)," enum-kotlin)
    (check-regexp-match #rx"suspend fun echo_role\\(role: Role\\): Role" enum-kotlin)
    (check-regexp-match #rx"Role\\.fromWireName" enum-kotlin)

    (define enum-baseline-path (build-path project-root "enum-schema.json"))
    (write-schema-snapshot! project enum-baseline-path)
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-enum Role (admin member guest))
(define-rpc (echo-role [role : Role] : Role) role)
(define (start in-fd out-fd) (serve-fds in-fd out-fd))
RKT
     )
    (define changed-enum-report
      (check-schema-compatibility! project enum-baseline-path))
    (check-false (hash-ref changed-enum-report 'compatible))
    (check-equal? (hash-ref (first (hash-ref changed-enum-report 'breaking-changes))
                            'name)
                  "Role")

    ;; Schema names live below a generated namespace, so common domain names
    ;; do not shadow Swift.Task, Swift.Result, or future standard-library types
    ;; throughout the application module.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-record Task ([title : String]))
(define-rpc (lookup-task : Task) (Task "demo"))
(define (start in-fd out-fd) (serve-fds in-fd out-fd))
RKT
     )
    (generate-clients! project)
    (define namespaced-swift
      (file->string
       (build-path project-root
                   "macos-host" "Sources" "RivetHost" "GeneratedBackend.swift")))
    (check-regexp-match #rx"public enum RivetTypes" namespaced-swift)
    (check-regexp-match #rx"    public struct Task: Sendable" namespaced-swift)
    (check-false (regexp-match? #px"(?m:^public struct Task:)" namespaced-swift))
    (check-regexp-match
     #rx"func lookup_task\\(\\) async throws -> RivetTypes.Task"
     namespaced-swift)

    ;; Distinct Racket identifiers can normalize to the same native API name.
    ;; Codegen must reject these cases instead of emitting uncompilable Swift/C++.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-rpc (foo-bar [value Int64] : Int64) value)
(define-rpc (foo_bar [value Int64] : Int64) value)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; Swift declaration keywords must be normalized before source emission.
    ;; `init` is especially easy to miss because it remains legal in C++.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-rpc (init : Void) (void))
(define-rpc (public : Bool) #t)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (generate-clients! project)
    (define keyword-swift
      (file->string
       (build-path project-root
                   "macos-host"
                   "Sources"
                   "RivetHost"
                   "GeneratedBackend.swift")))
    (check-regexp-match #rx"public func rivet_init\\(\\) async throws -> Void"
                        keyword-swift)
    (check-regexp-match #rx"public func rivet_public\\(\\) async throws -> Bool"
                        keyword-swift)

    ;; Put the complete collision in the first line because CI wrappers and
    ;; agent logs often retain only that line of a Racket exception.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-state config : String "")
(define-rpc (set-config [value : String] : Void) (void))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (define state-collision-message
      (with-handlers ([exn:fail? exn-message])
        (generate-clients! project)
        ""))
    (check-regexp-match
     #rx"Swift API native API name collision: RPC set-config and State setter config both generate set_config"
     state-collision-message)

    ;; Generated async companions are part of the C++ API namespace too.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-rpc (foo [value Int64] : Int64) value)
(define-rpc (foo_async [value Int64] : Int64) value)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; The same guard applies to argument names inside a generated method.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-rpc (combine [foo-bar Int64] [foo_bar Int64] : Int64)
  (+ foo-bar foo_bar))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; Event case names are normalized too and need the same collision safety.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-event foo-bar : Int64)
(define-event foo_bar : Int64)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; Enum cases must also remain distinct after native normalization.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-enum Mode (foo-bar foo_bar))
(define-rpc (mode : Mode) (Mode 'foo-bar))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project)))

    ;; Kotlin event payloads become nested data classes with UpperFirst names,
    ;; so events differing only in case would collapse onto one class.
    (write-backend!
     project-root
     #<<RKT
#lang racket/base

(require rivet/backend)
(provide start)

(define-event foo : Int64)
(define-event Foo : Int64)

(define-rpc (health : Bool) #t)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
     )
    (check-exn #rx"native API name collision"
               (lambda () (generate-clients! project))))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
