#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "../rivet/distribution/crypto.rkt"
         "linux-package.rkt"
         "project.rkt"
         "signing-options.rkt"
         "tar.rkt"
         "windows-tools.rkt")

(provide verify-package!
         verify-project-package!)

(define (required-file! who path label)
  (unless (file-exists? path)
    (raise-arguments-error who
                           "packaged artifact is missing a required file"
                           "file" path
                           "purpose" label)))

(define (required-directory! who path label)
  (unless (directory-exists? path)
    (raise-arguments-error who
                           "packaged artifact is missing a required directory"
                           "directory" path
                           "purpose" label)))

(define (verify-configured-resources! who project packaged-root)
  (define app-info-path
    (build-path packaged-root "app" "rivet-app-info.rktd"))
  (required-file! who app-info-path "generated application identity")
  (define-values (app-info trailing)
    (call-with-input-file app-info-path
      (lambda (in) (values (read in) (read in)))))
  (define expected-app-info
    (hasheq 'name (project-name project)
            'display-name (project-display-name project)
            'version (project-version project)
            'build (project-build project)
            'identifier (project-identifier project)
            'release-channel (project-release-channel project)))
  (unless (and (eof-object? trailing) (equal? app-info expected-app-info))
    (raise-arguments-error who
                           "packaged application identity does not match rivet.rktd"
                           "file" app-info-path
                           "expected" expected-app-info
                           "actual" app-info))
  (for ([configured-path (in-list (project-resources project))])
    (define relative (string->path configured-path))
    (define source (project-path project relative))
    (define destination (build-path packaged-root "app" relative))
    (cond
      [(file-exists? source)
       (required-file! who destination "configured application resource")]
      [(directory-exists? source)
       (required-directory! who destination "configured application resource directory")
       (for ([source-file (in-list (find-files file-exists? source))])
         (required-file!
          who
          (build-path destination (find-relative-path source source-file))
          "configured application resource file"))]
      [else
       (raise-arguments-error who
                              "configured application resource disappeared before verification"
                              "resource" configured-path
                              "source" source)])))

(define (capture-command! who executable . args)
  (unless executable
    (error who "required verification executable was not found"))
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system* executable args)))
  (unless ok?
    (raise-arguments-error
     who
     "verification command failed"
     "executable" executable
     "arguments" args
     "stderr" (string-trim (get-output-string err))))
  (string-append (get-output-string out) (get-output-string err)))

(define (run-command! who executable . args)
  (apply capture-command! who executable args)
  (void))

(define (file-name-lower path)
  (string-downcase (path->string (file-name-from-path path))))

(define (windows-binary? path)
  (and (file-exists? path)
       (regexp-match? #px"(?i:\\.(exe|dll)$)" (path->string path))))

(define (parse-dumpbin-dependencies text)
  (remove-duplicates
   (filter
    values
    (for/list ([line (in-list (string-split text "\n"))])
      (define match
        (regexp-match #px"(?i:^\\s*([A-Za-z0-9_.+-]+\\.dll)\\s*$)" line))
      (and match (string-downcase (cadr match)))))
   string=?))

(define (windows-api-set? dll)
  (or (string-prefix? dll "api-ms-win-")
      (string-prefix? dll "ext-ms-win-")))

(define (windows-system-dll? dll)
  (or (windows-api-set? dll)
      (let ([root (getenv "WINDIR")])
        (and root
             (or (file-exists? (build-path root "System32" dll))
                 (file-exists? (build-path root "SysWOW64" dll)))))))

(define (verify-windows-package! project package production?)
  (define who 'verify-package!)
  (required-directory! who package "Windows portable package")
  (define executable (build-path package "RivetHost.exe"))
  (required-file! who executable "WinUI executable")
  (required-file! who (build-path package "res" "core.zo") "compiled Racket backend")
  (for ([name (in-list '("petite.boot" "scheme.boot" "racket.boot"))])
    (required-file! who (build-path package "runtime" name) "embedded Racket boot file"))
  (verify-configured-resources! who project package)

  (define root-files
    (for/list ([entry (in-list (directory-list package))]
               #:do [(define full (build-path package entry))]
               #:when (file-exists? full))
      full))
  (unless (for/or ([path (in-list root-files)])
            (regexp-match? #px"(?i:racketcs.*\\.dll$)" (path->string path)))
    (error who "Windows package does not contain the embedded Racket CS DLL"))

  (define tools (discover-windows-toolchain))
  (define dumpbin (windows-toolchain-dumpbin tools))
  (unless dumpbin
    (error who
           "dumpbin.exe was not found; install the Visual Studio C++ tools so Rivet can audit packaged DLL dependencies"))

  (define packaged-names
    (for/hash ([path (in-list root-files)])
      (values (file-name-lower path) path)))

  ;; Audit every PE binary that participates in the package root. A dependency
  ;; is acceptable only when another packaged root file supplies it or Windows
  ;; itself supplies it. This catches accidental dependencies on a developer
  ;; machine's Racket/Visual Studio/Windows App Runtime installation.
  (for ([binary (in-list root-files)] #:when (windows-binary? binary))
    (define dependencies
      (parse-dumpbin-dependencies
       (capture-command! who dumpbin "/DEPENDENTS" (path->string binary))))
    (for ([dll (in-list dependencies)])
      (unless (or (hash-has-key? packaged-names dll)
                  (windows-system-dll? dll))
        (raise-arguments-error
         who
         "Windows package has an unresolved DLL dependency"
         "binary" binary
         "dependency" dll))))

  (when production?
    (define signtool (windows-toolchain-signtool tools))
    (unless signtool
      (error who
             "signtool.exe was not found; install the Windows SDK to verify Authenticode production packages"))
    (run-command! who signtool "verify" "/pa" "/v" (path->string executable)))
  package)

(define (verify-linux-production-installer! project package)
  (define who 'verify-package!)
  (define public-key-path (load-linux-production-verification))
  (define installer (linux-installer-path project))
  (required-file! who installer "Linux production installer archive")
  (define signature-path (string-append (path->string installer) ".sig"))
  (required-file! who signature-path "Linux installer Ed25519 signature")

  ;; The deterministic archive makes the released installer re-derivable from
  ;; the packaged directory: a byte-identical rebuild proves the archive
  ;; contains exactly what this verification inspected.
  (define released (file->bytes installer))
  (define rebuilt
    (gzip-archive-bytes
     (tar-directory->bytes
      package
      #:root-name (path->string (file-name-from-path package)))))
  (unless (equal? released rebuilt)
    (raise-arguments-error who
                           "Linux installer archive does not match the packaged directory"
                           "installer" installer
                           "package" package))

  (define signature
    (base64-string->bytes
     (string-trim (file->string signature-path))))
  (unless (ed25519-verify
           (read-ed25519-public-key (string->path public-key-path))
           released
           signature)
    (raise-arguments-error who
                           "Linux installer Ed25519 signature does not verify"
                           "installer" installer
                           "signature" signature-path
                           "public-key" public-key-path)))

(define (verify-linux-package! project package production?)
  (define who 'verify-package!)
  (required-directory! who package "Linux application package")
  (define executable (build-path package "RivetHost"))
  (required-file! who executable "GTK4 executable")
  (define permissions (file-or-directory-permissions executable))
  (unless (if (list? permissions)
              (and (memq 'execute permissions) #t)
              (positive? (bitwise-and permissions #o111)))
    (raise-arguments-error who
                           "packaged Linux host is not executable"
                           "file" executable))
  (required-file! who (build-path package "res" "core.zo") "compiled Racket backend")
  (for ([name (in-list '("petite.boot" "scheme.boot" "racket.boot"))])
    (required-file! who (build-path package "runtime" name) "embedded Racket boot file"))
  (verify-configured-resources! who project package)

  (define ldd (find-executable-path "ldd"))
  (define dependencies
    (capture-command! who ldd (path->string executable)))
  (when (regexp-match? #px"(?m:^.*=>\\s+not found\\s*$)" dependencies)
    (raise-arguments-error who
                           "Linux package has unresolved shared-library dependencies"
                           "file" executable
                           "ldd" dependencies))

  (when production?
    (verify-linux-production-installer! project package))
  package)

(define (verify-macos-package! project app production?)
  (define who 'verify-package!)
  (required-directory! who app "macOS app bundle")
  (define contents (build-path app "Contents"))
  (define info (build-path contents "Info.plist"))
  (define macos (build-path contents "MacOS"))
  (define resources (build-path contents "Resources"))
  (define frameworks (build-path contents "Frameworks"))
  (required-file! who info "application metadata")
  (required-directory! who macos "application executable directory")
  (required-directory! who resources "embedded Racket resources")
  (required-directory! who frameworks "embedded frameworks")

  (define executable-name
    (path->string (path-replace-extension (file-name-from-path app) #"")))
  (define executable (build-path macos executable-name))
  (define racket-framework (build-path frameworks "Racket.framework"))
  (define racket-binary (build-path racket-framework "Racket"))
  (required-file! who executable "SwiftUI executable")
  (required-file! who (build-path resources "res" "core.zo") "compiled Racket backend")
  (for ([name (in-list '("petite.boot" "scheme.boot" "racket.boot"))])
    (required-file! who (build-path resources "runtime" name) "embedded Racket boot file"))
  (verify-configured-resources! who project resources)
  (required-directory! who racket-framework "embedded Racket.framework")
  (required-file! who racket-binary "embedded Racket.framework executable")

  (define codesign (find-executable-path "codesign"))
  (define otool (find-executable-path "otool"))
  (define plutil (find-executable-path "plutil"))
  (unless codesign (error who "codesign was not found"))
  (unless otool (error who "otool was not found"))
  (unless plutil (error who "plutil was not found"))

  (run-command! who codesign "--verify" "--strict" (path->string racket-framework))
  (run-command! who codesign "--verify" "--deep" "--strict" (path->string app))

  (define linked-libraries
    (capture-command! who otool "-L" (path->string executable)))
  (unless (regexp-match? #px"@rpath/Racket\\.framework/" linked-libraries)
    (raise-arguments-error
     who
     "macOS executable does not reference the bundled Racket.framework through @rpath"
     "executable" executable
     "otool -L" linked-libraries))
  (when (for/or ([line (in-list (string-split linked-libraries "\n"))])
          (and (regexp-match? #px"^\\s*/" line)
               (string-contains? line "Racket.framework/")))
    (raise-arguments-error
     who
     "macOS executable still references an absolute developer-machine Racket.framework path"
     "executable" executable
     "otool -L" linked-libraries))

  (define load-commands
    (capture-command! who otool "-l" (path->string executable)))
  (unless (regexp-match? #rx"path @executable_path/../Frameworks" load-commands)
    (raise-arguments-error
     who
     "macOS executable is missing the app-bundle Frameworks rpath"
     "expected" "@executable_path/../Frameworks"))

  (define framework-id
    (capture-command! who otool "-D" (path->string racket-binary)))
  (unless (regexp-match? #px"@rpath/Racket\\.framework/Versions/[^/]+/Racket" framework-id)
    (raise-arguments-error
     who
     "Racket.framework has an unexpected install name"
     "otool -D" framework-id))

  (run-command! who plutil "-lint" (path->string info))
  (define packaged-minimum-version
    (string-trim
     (capture-command! who
                       plutil
                       "-extract" "LSMinimumSystemVersion" "raw"
                       "-o" "-"
                       (path->string info))))
  (define configured-minimum-version (project-macos-min-version project))
  (unless (string=? packaged-minimum-version configured-minimum-version)
    (raise-arguments-error
     who
     "macOS package minimum version does not match rivet.rktd"
     "configured" configured-minimum-version
     "packaged" packaged-minimum-version
     "Info.plist" info))

  (when (project-macos-icon project)
    (required-file! who (build-path resources "AppIcon.icns") "configured macOS application icon")
    (define packaged-icon
      (string-trim
       (capture-command! who
                         plutil
                         "-extract" "CFBundleIconFile" "raw"
                         "-o" "-"
                         (path->string info))))
    (unless (string=? packaged-icon "AppIcon.icns")
      (raise-arguments-error
       who
       "macOS package icon metadata does not match the packaged icon"
       "configured" (project-macos-icon project)
       "packaged" packaged-icon
       "Info.plist" info)))

  (when production?
    (define xcrun (find-executable-path "xcrun"))
    (define spctl (find-executable-path "spctl"))
    (unless xcrun
      (error who "xcrun was not found; cannot validate notarization ticket"))
    (unless spctl
      (error who "spctl was not found; cannot assess production macOS package"))
    (run-command! who xcrun "stapler" "validate" (path->string app))
    (run-command! who spctl
                  "--assess" "--type" "execute" "--verbose=4"
                  (path->string app)))
  app)

(define (verify-package! project package #:production? [production? #f])
  (case (system-type 'os)
    [(windows) (verify-windows-package! project package production?)]
    [(macosx) (verify-macos-package! project package production?)]
    [(unix) (verify-linux-package! project package production?)]
    [else
     (error 'verify-package!
            "Rivet package verification currently targets Windows, macOS, and Linux")]))

(define (verify-project-package! project #:production? [production? #f])
  (define name (project-ref project 'name))
  (define package
    (case (system-type 'os)
      [(windows)
       (define architecture
         (case (system-type 'arch)
           [(aarch64 arm64) "arm64"]
           [else "x64"]))
       (project-path project "dist" (string-append name "-windows-" architecture))]
      [(macosx)
       (project-path project "dist" (string-append name ".app"))]
      [(unix)
       (project-path project "dist" (linux-package-directory-name project))]
      [else
       (error 'verify-project-package!
              "Rivet package verification currently targets Windows, macOS, and Linux")]))
  (verify-package! project package #:production? production?))

(module+ test-support
  (provide verify-configured-resources!))
