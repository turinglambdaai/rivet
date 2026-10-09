#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/runtime-path
         racket/string
         racket/system
         "codegen.rkt"
         "project.rkt"
         "runtime.rkt"
         "windows-tools.rkt")

(provide build-project!
         dev-project!
         required-project-icon)

(define-runtime-path rivet-root "..")

(define (windows-platform)
  (case (system-type 'arch)
    [(x86_64) "x64"]
    [(aarch64 arm64) "ARM64"]
    [else
     (error 'build-project!
            "Windows builds support x64 and ARM64 hosts; current architecture is ~a"
            (system-type 'arch))]))

(define (run! who executable . args)
  (unless executable
    (error who "required executable was not found"))
  (unless (apply system* executable args)
    (raise-arguments-error who
                           "external command failed"
                           "executable" executable
                           "arguments" args)))

(define (fresh-directory! path)
  (when (directory-exists? path)
    (delete-directory/files path))
  (make-directory* path))

(define (copy-required! who source destination)
  (unless (file-exists? source)
    (raise-arguments-error who "required source file does not exist"
                           "source" source))
  (make-parent-directory* destination)
  (copy-file source destination #t))

(define (check-portable-resource-tree! source configured-path)
  (when (link-exists? source)
    (raise-arguments-error 'build-project!
                           "application resources must not contain symbolic links or junctions"
                           "resource" configured-path
                           "link" source))
  (when (directory-exists? source)
    (for ([entry (in-list (directory-list source #:build? #t))])
      (check-portable-resource-tree! entry configured-path))))

(define (copy-project-resources! project stage)
  (define resources (project-resources project))
  (unless (null? resources)
    (define destination-root (build-path stage "app"))
    (make-directory* destination-root)
    (for ([configured-path (in-list resources)])
      (define relative (string->path configured-path))
      (define source (project-path project relative))
      (define destination (build-path destination-root relative))
      (unless (or (file-exists? source) (directory-exists? source))
        (raise-arguments-error 'build-project!
                               "configured application resource does not exist"
                               "resource" configured-path
                               "source" source))
      (check-portable-resource-tree! source configured-path)
      (when (or (file-exists? destination) (directory-exists? destination))
        (raise-arguments-error 'build-project!
                               "configured application resources overlap"
                               "resource" configured-path
                               "destination" destination))
      (make-parent-directory* destination)
      (if (directory-exists? source)
          (copy-directory/files source destination)
          (copy-file source destination)))))

(define (write-app-info! project stage)
  (define destination-root (build-path stage "app"))
  (define destination (build-path destination-root "rivet-app-info.rktd"))
  (when (or (file-exists? destination)
            (directory-exists? destination)
            (link-exists? destination))
    (raise-arguments-error 'build-project!
                           "application resources use Rivet's reserved metadata path"
                           "path" destination))
  (make-directory* destination-root)
  (call-with-output-file destination
    #:exists 'error
    (lambda (out)
      (write
       (hasheq 'name (project-name project)
               'display-name (project-display-name project)
               'version (project-version project)
               'build (project-build project)
               'identifier (project-identifier project)
               'release-channel (project-release-channel project))
       out)
      (newline out))))

(define (required-project-icon project configured-path platform)
  (and configured-path
       (let ([source (project-path project configured-path)])
         (unless (file-exists? source)
           (raise-arguments-error 'build-project!
                                  "configured application icon does not exist"
                                  "platform" platform
                                  "icon" configured-path
                                  "source" source))
         (when (link-exists? source)
           (raise-arguments-error 'build-project!
                                  "application icons must not be symbolic links or junctions"
                                  "platform" platform
                                  "icon" configured-path
                                  "link" source))
         source)))

;; Escapes a string for an RC string-table value: RC string literals
;; escape quotes and backslashes.
(define (rc-escape value)
  (string-append "\""
                 (string-replace (string-replace value "\\" "\\\\")
                                 "\"" "\\\"")
                 "\""))

;; Renders the VERSIONINFO block from the project manifest so the shipped
;; exe carries its identity in Explorer, Task Manager, and installer UX.
(define (write-windows-version-info! out project)
  (define name (project-name project))
  (define display-name (project-display-name project))
  (define publisher (project-publisher project))
  (define version (project-version project))
  (define build-number (project-build project))
  (define raw-numbers
    (append (map (lambda (piece) (or (string->number piece) 0))
                 (string-split version "."))
            (list build-number)))
  (define four-tuple
    (string-join
     (for/list ([part (in-list
                       (append raw-numbers
                               (build-list (max 0 (- 4 (length raw-numbers)))
                                           (lambda (_) 0))))])
       (~a part))
     ", "))
  (define dotted (format "~a.~a" version build-number))
  (define version-block
    (string-append
     "#include <windows.h>\n\nVS_VERSION_INFO VERSIONINFO\n"
     " FILEVERSION     " four-tuple "\n"
     " PRODUCTVERSION  " four-tuple "\n"
     " FILEFLAGSMASK   VS_FFI_FILEFLAGSMASK\n"
     " FILEFLAGS       0x0L\n"
     " FILEOS          VOS_NT_WINDOWS32\n"
     " FILETYPE        VFT_APP\n"
     " FILESUBTYPE     VFT2_UNKNOWN\n"
     "BEGIN\n"
     "    BLOCK \"StringFileInfo\"\n"
     "    BEGIN\n"
     "        BLOCK \"040904B0\"\n"
     "        BEGIN\n"
     "            VALUE \"CompanyName\",      " (rc-escape publisher) "\n"
     "            VALUE \"FileDescription\",  " (rc-escape display-name) "\n"
     "            VALUE \"FileVersion\",      " (rc-escape dotted) "\n"
     "            VALUE \"InternalName\",     " (rc-escape name) "\n"
     "            VALUE \"OriginalFilename\", " (rc-escape (string-append name ".exe")) "\n"
     "            VALUE \"ProductName\",      " (rc-escape display-name) "\n"
     "            VALUE \"ProductVersion\",   " (rc-escape dotted) "\n"
     "        END\n"
     "    END\n"
     "    BLOCK \"VarFileInfo\"\n"
     "    BEGIN\n"
     "        VALUE \"Translation\", 0x0409, 1200\n"
     "    END\n"
     "END\n"))
  (display version-block out))

(define (prepare-windows-icon-resource! project)
  (define source
    (required-project-icon project (project-windows-icon project) 'windows))
  ;; The resource script always carries a VERSIONINFO block so the shipped
  ;; exe has an identity even for projects without an icon; the ICON line
  ;; rides along when one is declared.
  (define resource-script
    (project-path project ".rivet" "build" "windows" "app-icon.rc"))
  (make-parent-directory* resource-script)
  (call-with-output-file resource-script
    #:exists 'truncate/replace
    (lambda (out)
      (when source
        ;; Resource Compiler treats backslashes as escapes inside quoted
        ;; paths. Forward slashes are accepted by Windows tools and keep
        ;; arbitrary project directory names unambiguous.
        (define portable
          (string-replace (path->string source) "\\" "/"))
        (fprintf out "IDI_RIVET_APP_ICON ICON \"~a\"\n" portable))
      (write-windows-version-info! out project)))
  resource-script)

(define (compile-backend! project runtime stage)
  (define backend-relative (project-ref project 'backend))
  (define backend (project-path project backend-relative))
  (unless (file-exists? backend)
    (raise-arguments-error 'build-project!
                           "configured backend module does not exist"
                           "backend" backend))

  (define res-dir (build-path stage "res"))
  (define runtime-dir (build-path stage "runtime"))
  (make-directory* res-dir)
  (make-directory* runtime-dir)

  (define core (build-path res-dir "core.zo"))
  (compile-backend-module-bundle! backend core runtime-dir)

  (for ([source (in-list
                 (list (racket-runtime-petite-boot runtime)
                       (racket-runtime-scheme-boot runtime)
                       (racket-runtime-racket-boot runtime)))])
    (copy-required! 'build-project!
                    source
                    (build-path runtime-dir (file-name-from-path source))))
  core)

(define (compile-backend-module-bundle! backend core [runtime-dir #f])
  (define raco (find-executable-path "raco"))
  ;; `raco ctool --mods` can consume an existing compiled entry module without
  ;; refreshing its transitive dependencies. Compile the dependency graph first
  ;; so same-length source edits cannot leave stale bytecode in the bundle.
  (run! 'build-project! raco "make" (path->string backend))
  (apply run!
         'build-project!
         raco
         "ctool"
         (append
          (if runtime-dir
              (list "--runtime" (path->string runtime-dir)
                    "--runtime-access" "runtime")
              '())
          (list "--mods" (path->string core)
                (path->string backend)))))

(define (prepare-windows-import-library! project runtime lib-exe)
  (unless lib-exe
    (error 'build-project!
           "MSVC lib.exe was not found; install Visual Studio Build Tools with the Desktop development with C++ workload"))

  (define build-dir (project-path project ".rivet" "build" "windows"))
  (make-directory* build-dir)
  (define output (build-path build-dir "libracketcs.lib"))
  (define def (racket-runtime-racketcs-def runtime))

  (run! 'build-project!
        lib-exe
        (string-append "/def:" (path->string def))
        (string-append "/out:" (path->string output))
        (string-append "/machine:" (string-downcase (windows-platform))))
  output)

(define (with-windows-build-environment project runtime import-lib icon-resource thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (define (set-path! key path)
    (environment-variables-set! env key (path->bytes path)))
  (set-path! #"RIVET_ROOT" (simplify-path rivet-root #t))
  (set-path! #"RIVET_RACKET_INCLUDE" (racket-runtime-include-dir runtime))
  (set-path! #"RIVET_RACKET_IMPORT_LIB" import-lib)
  (environment-variables-set!
   env
   #"RIVET_WINDOWS_MIN_VERSION"
   (string->bytes/utf-8 (project-windows-min-version project)))
  (environment-variables-set!
   env
   #"RIVET_WINDOWS_ICON_RC"
   (if icon-resource (path->bytes icon-resource) #""))
  (parameterize ([current-environment-variables env])
    (thunk)))

(define (build-windows! project runtime stage configuration self-contained?)
  (define host-project (project-path project "windows" "RivetHost.vcxproj"))
  (unless (file-exists? host-project)
    (raise-arguments-error 'build-project!
                           "Windows host project is missing"
                           "expected" host-project))

  (define toolchain (discover-windows-toolchain))
  (define import-lib
    (prepare-windows-import-library!
     project runtime (windows-toolchain-lib toolchain)))
  (define icon-resource (prepare-windows-icon-resource! project))
  (define racketcs-dll (racket-runtime-racketcs-dll runtime))
  (copy-required! 'build-project!
                  racketcs-dll
                  (build-path stage (file-name-from-path racketcs-dll)))

  (define msbuild (windows-toolchain-msbuild toolchain))
  (unless msbuild
    (error 'build-project!
           "MSBuild.exe was not found; install Visual Studio Build Tools with C++/WinUI support"))

  (define out-dir (path->string stage))
  (with-windows-build-environment
   project runtime import-lib icon-resource
   (lambda ()
     (run! 'build-project!
           msbuild
           (path->string host-project)
           "/restore"
           "/m"
           ;; On ARM64 Windows hosts MSBuild otherwise selects the 32-bit
           ;; HostX86 cross compiler, whose address space cannot hold the
           ;; WinUI precompiled header (C3859/C1076). The x64-hosted toolchain
           ;; is already a hard requirement of Rivet's toolchain discovery.
           "/p:PreferredToolArchitecture=x64"
           (string-append "/p:Configuration=" configuration)
           (string-append "/p:Platform=" (windows-platform))
           (string-append "/p:RivetSelfContained="
                          (if self-contained? "true" "false"))
           (string-append "/p:OutDir=" out-dir))))
  (build-path stage "RivetHost.exe"))

(define (with-macos-build-environment project framework-dir thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set!
   env #"RIVET_ROOT" (path->bytes (simplify-path rivet-root #t)))
  (environment-variables-set!
   env #"RIVET_RACKET_FRAMEWORK_DIR" (path->bytes framework-dir))
  (environment-variables-set!
   env #"RIVET_MACOS_MIN_VERSION"
   (string->bytes/utf-8 (project-macos-min-version project)))
  (parameterize ([current-environment-variables env])
    (thunk)))

(define (find-built-macos-executable build-dir)
  (define candidates
    (find-files
     (lambda (p)
       (and (file-exists? p)
            (let ([name (file-name-from-path p)])
              (and name (string=? (path->string name) "RivetHost")))))
     build-dir))
  (or (for/first ([p (in-list candidates)]
                  #:when (regexp-match? #rx"/(debug|release)/RivetHost$"
                                        (path->string p)))
        p)
      (and (pair? candidates) (car candidates))
      (error 'build-project! "Swift build completed but RivetHost was not found")))

(define (framework-version-string version-name)
  (regexp-replace #rx"_CS$" version-name ""))

(define (write-framework-info! version-dir version-name)
  (define resources-dir (build-path version-dir "Resources"))
  (make-directory* resources-dir)
  (define version (framework-version-string version-name))
  (call-with-output-file (build-path resources-dir "Info.plist")
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out
               "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>CFBundleDevelopmentRegion</key><string>en</string>\n  <key>CFBundleExecutable</key><string>Racket</string>\n  <key>CFBundleIdentifier</key><string>org.racket-lang.Racket</string>\n  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n  <key>CFBundleName</key><string>Racket</string>\n  <key>CFBundlePackageType</key><string>FMWK</string>\n  <key>CFBundleShortVersionString</key><string>~a</string>\n  <key>CFBundleVersion</key><string>~a</string>\n</dict>\n</plist>\n"
               version
               version))))

(define (prepare-macos-framework! runtime stage)
  (define source (racket-runtime-racket-framework runtime))
  (unless source
    (error 'build-project! "the installed Racket CS does not provide Racket.framework"))

  (define frameworks-dir (build-path stage "Frameworks"))
  (define destination (build-path frameworks-dir "Racket.framework"))
  (make-directory* frameworks-dir)

  ;; Preserve the framework's versioned layout and any installer-provided links.
  (define ditto (find-executable-path "ditto"))
  (run! 'build-project! ditto (path->string source) (path->string destination))

  (define versions-dir (build-path destination "Versions"))
  (define version-dirs
    (sort
     (for/list ([entry (in-list (directory-list versions-dir))]
                #:do [(define name (path->string entry))
                      (define full (build-path versions-dir entry))]
                #:when (and (not (string=? name "Current"))
                            (directory-exists? full)
                            (file-exists? (build-path full "Racket"))))
       full)
     string<?
     #:key path->string))
  (define version-dir
    (or (for/first ([candidate (in-list version-dirs)]
                    #:when (regexp-match? #rx"_CS$"
                                          (path->string (file-name-from-path candidate))))
          candidate)
        (and (pair? version-dirs) (car version-dirs))
        (error 'build-project!
               "Racket.framework contains no usable version directory")))
  (define version-name (path->string (file-name-from-path version-dir)))

  ;; Turn the installer payload into a conventional framework bundle. Besides
  ;; helping ld discover it, the plist and symlinks are required for codesign to
  ;; recognize the nested framework inside the final .app.
  (write-framework-info! version-dir version-name)
  (define ln (find-executable-path "ln"))
  (run! 'build-project! ln "-sfn" version-name
        (path->string (build-path versions-dir "Current")))
  (run! 'build-project! ln "-sfn" "Versions/Current/Racket"
        (path->string (build-path destination "Racket")))
  (run! 'build-project! ln "-sfn" "Versions/Current/Resources"
        (path->string (build-path destination "Resources")))

  ;; Make the linked executable refer to the bundled framework through rpath
  ;; instead of the Racket installation path.
  (define install-name-tool (find-executable-path "install_name_tool"))
  (define inner-dylib (build-path version-dir "Racket"))
  (run! 'build-project!
        install-name-tool
        "-id"
        (format "@rpath/Racket.framework/Versions/~a/Racket" version-name)
        (path->string inner-dylib))

  ;; install_name_tool invalidated the dylib's embedded signature, and the
  ;; dev loop (`raco rivet dev`) launches this stage directly — package-time
  ;; signing never runs for it. On arm64 AMFI kills the process at page-in,
  ;; so re-sign ad-hoc here: the inner Mach-O first, then the wrapper
  ;; (signing the bundle alone leaves the inner dylib stale).
  (define codesign (find-executable-path "codesign"))
  (unless codesign
    (error 'build-project! "codesign was not found; install Xcode command line tools"))
  (run! 'build-project! codesign "--force" "--sign" "-" (path->string inner-dylib))
  (run! 'build-project! codesign "--force" "--sign" "-" (path->string destination))

  frameworks-dir)

(define (build-macos! project runtime stage configuration)
  (define swift (find-executable-path "swift"))
  (unless swift
    (error 'build-project! "swift was not found; install Xcode command line tools"))

  (define framework-dir (prepare-macos-framework! runtime stage))

  (define host-dir (project-path project "macos-host"))
  (define package-file (build-path host-dir "Package.swift"))
  (unless (file-exists? package-file)
    (raise-arguments-error 'build-project!
                           "macOS host package is missing"
                           "expected" package-file))

  (define build-dir (project-path project ".rivet" "build" "macos"))
  (make-directory* build-dir)
  (define swift-configuration (string-downcase configuration))

  (with-macos-build-environment
   project framework-dir
   (lambda ()
     (run! 'build-project!
           swift
           "build"
           "--package-path" (path->string host-dir)
           "--scratch-path" (path->string build-dir)
           "-c" swift-configuration
           "-Xcc" (string-append "-I" (path->string (racket-runtime-include-dir runtime)))
           "-Xlinker" "-rpath"
           "-Xlinker" "@executable_path/Frameworks"
           "-Xlinker" "-rpath"
           "-Xlinker" "@executable_path/../Frameworks")))

  (define built (find-built-macos-executable build-dir))
  (define staged-executable (build-path stage "RivetHost"))
  (copy-required! 'build-project! built staged-executable)
  (file-or-directory-permissions staged-executable #o755)
  ;; SwiftPM emits resource bundles (RivetHost_*.bundle) next to the built
  ;; executable. Stage them beside RivetHost so `raco rivet dev`, which runs
  ;; the stage directly, finds them through resource_bundle_accessor's
  ;; Bundle.main.bundleURL lookup. Packaging refuses them instead of copying
  ;; them into the .app: the accessor's .app-root location is unsealed
  ;; content that codesign rejects, so SwiftPM-declared resources cannot
  ;; ship in signed packages (package-macos! fails closed with a migration
  ;; message; declare shared data in rivet.rktd `resources` instead).
  (define built-dir (path-only built))
  (for ([entry (in-list (directory-list built-dir))]
        #:when (regexp-match? #rx"[.]bundle$" (path->string entry)))
    (define destination (build-path stage entry))
    (when (directory-exists? destination)
      (delete-directory/files destination))
    (copy-directory/files (build-path built-dir entry) destination))
  staged-executable)

(define (with-linux-build-environment runtime thunk)
  (define library (racket-runtime-racketcs-static runtime))
  (unless library
    (error 'build-project!
           "the Linux build requires an embeddable static libracketcs; set RIVET_RACKET_LIBRARY to libracketcs.a"))
  (define env (environment-variables-copy (current-environment-variables)))
  (define (set-path! key path)
    (environment-variables-set! env key (path->bytes path)))
  (set-path! #"RIVET_ROOT" (simplify-path rivet-root #t))
  (set-path! #"RIVET_RACKET_INCLUDE" (racket-runtime-include-dir runtime))
  (set-path! #"RIVET_RACKET_LIBRARY" library)
  (parameterize ([current-environment-variables env])
    (thunk)))

(define (build-linux! project runtime stage configuration)
  (define cmake (find-executable-path "cmake"))
  (unless cmake
    (error 'build-project! "cmake was not found; install the Linux native toolchain"))
  (define host-dir (project-path project "linux"))
  (unless (directory-exists? host-dir)
    (raise-arguments-error 'build-project!
                           "Linux host directory is missing; add the current Rivet Linux host template"
                           "directory" host-dir))
  (define build-dir (project-path project ".rivet" "build" "linux"))
  (fresh-directory! build-dir)
  (with-linux-build-environment
   runtime
   (lambda ()
     (run! 'build-project!
           cmake
           "-S" (path->string host-dir)
           "-B" (path->string build-dir)
           (string-append "-DCMAKE_BUILD_TYPE=" configuration))
     (run! 'build-project!
           cmake
           "--build" (path->string build-dir)
           "--config" configuration)))
  ;; The app's CMake must produce the configured binary name
  ;; (linux-binary-name, default RivetHost) — set_target_properties
  ;; OUTPUT_NAME in the host CMakeLists when it is not the default.
  (define binary-name (project-linux-binary-name project))
  (define built (build-path build-dir binary-name))
  (define staged-executable (build-path stage binary-name))
  (copy-required! 'build-project! built staged-executable)
  (file-or-directory-permissions staged-executable #o755)
  staged-executable)

(define (build-project! project
                        #:configuration [configuration "Debug"]
                        #:self-contained? [self-contained? #f])
  (generate-clients! project)
  (define runtime (discover-racket-runtime))
  (define stage (project-path project ".rivet" "stage"))
  (fresh-directory! stage)
  (compile-backend! project runtime stage)
  (copy-project-resources! project stage)
  (write-app-info! project stage)

  (case (system-type 'os)
    [(windows)
     (build-windows! project runtime stage configuration self-contained?)]
    [(macosx)
     (build-macos! project runtime stage configuration)]
    [(unix)
     (build-linux! project runtime stage configuration)]
    [else
     (error 'build-project!
            "Rivet native hosts currently target Windows, macOS, and Linux")]))

(define (dev-project! project)
  ;; Development should start the generated app on a clean machine, not fail
  ;; because a matching Windows App Runtime happens not to be installed.
  (define executable
    (build-project! project
                    #:configuration "Debug"
                    #:self-contained? #t))
  (case (system-type 'os)
    [(windows macosx unix)
     (parameterize ([current-directory (path-only executable)])
       (run! 'dev-project! executable))]
    [else
     (error 'dev-project! "development runner is not available on this platform")]))

(module+ test-support
  (provide copy-project-resources!
           write-app-info!
           required-project-icon
           prepare-windows-icon-resource!
           compile-backend-module-bundle!))
