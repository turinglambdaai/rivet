#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "project.rkt"
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
  (get-output-string out))

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

(define (verify-windows-package! package)
  (define who 'verify-package!)
  (required-directory! who package "Windows portable package")
  (required-file! who (build-path package "RivetHost.exe") "WinUI executable")
  (required-file! who (build-path package "res" "core.zo") "compiled Racket backend")
  (for ([name (in-list '("petite.boot" "scheme.boot" "racket.boot"))])
    (required-file! who (build-path package "runtime" name) "embedded Racket boot file"))

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
  package)

(define (verify-macos-package! app)
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
  (required-directory! who racket-framework "embedded Racket.framework")
  (required-file! who racket-binary "embedded Racket.framework executable")

  (define codesign (find-executable-path "codesign"))
  (define otool (find-executable-path "otool"))
  (unless codesign (error who "codesign was not found"))
  (unless otool (error who "otool was not found"))

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
  (when (regexp-match? #px"(?m:^\\s*/[^\\n]*Racket\\.framework/)" linked-libraries)
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

  (define plutil (find-executable-path "plutil"))
  (when plutil
    (run-command! who plutil "-lint" (path->string info)))
  app)

(define (verify-package! project package)
  (case (system-type 'os)
    [(windows) (verify-windows-package! package)]
    [(macosx) (verify-macos-package! package)]
    [else
     (error 'verify-package!
            "Rivet package verification currently targets Windows and macOS")]))

(define (verify-project-package! project)
  (define name (project-ref project 'name))
  (define package
    (case (system-type 'os)
      [(windows)
       (project-path project "dist" (string-append name "-windows-x64"))]
      [(macosx)
       (project-path project "dist" (string-append name ".app"))]
      [else
       (error 'verify-project-package!
              "Rivet package verification currently targets Windows and macOS")]))
  (verify-package! project package))
