#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system)

(provide (struct-out windows-toolchain)
         discover-windows-toolchain)

(struct windows-toolchain (msbuild cl lib dumpbin signtool vswhere) #:transparent)

(define (existing-file path)
  (and path (file-exists? path) (simplify-path path #t)))

(define (existing-directory path)
  (and path (directory-exists? path) (simplify-path path #t)))

(define (safe-directory-list dir)
  (with-handlers ([exn:fail:filesystem? (lambda (_) '())])
    (directory-list dir #:build? #t)))

(define (candidate-vswhere)
  (or (existing-file (find-executable-path "vswhere.exe"))
      (for/or ([root (in-list
                      (filter values
                              (list (getenv "ProgramFiles(x86)")
                                    (getenv "ProgramFiles"))))])
        (existing-file
         (build-path root
                     "Microsoft Visual Studio"
                     "Installer"
                     "vswhere.exe")))))

(define (capture-command executable args)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system* executable args)))
  (and ok? (string-trim (get-output-string out))))

(define (first-existing-directory-line text)
  (and text
       (for/or ([line (in-list (string-split text "\n"))])
         (define candidate (string-trim line))
         (and (not (string=? candidate ""))
              (existing-directory (string->path candidate))))))

(define (vswhere-installation-root vswhere component)
  (first-existing-directory-line
   (capture-command
    vswhere
    (list "-latest"
          "-products" "*"
          "-requires" component
          "-property" "installationPath"))))

(define (sorted-child-directories root)
  (if (directory-exists? root)
      (sort
       (filter directory-exists? (safe-directory-list root))
       string>?
       #:key path->string)
      '()))

(define (msbuild-in-installation root)
  (and root
       (let ([msbuild-root (build-path root "MSBuild")])
         (or (existing-file
              (build-path msbuild-root "Current" "Bin" "MSBuild.exe"))
             (for/or ([entry (in-list (sorted-child-directories msbuild-root))])
               (existing-file (build-path entry "Bin" "MSBuild.exe")))))))

(define (vc-toolset-in-installation root)
  (and root
       (let ([toolsets-root (build-path root "VC" "Tools" "MSVC")])
         (for/or ([toolset (in-list (sorted-child-directories toolsets-root))])
           (define bin-dir (build-path toolset "bin" "Hostx64" "x64"))
           (define cl (existing-file (build-path bin-dir "cl.exe")))
           (define lib (existing-file (build-path bin-dir "lib.exe")))
           (define dumpbin (existing-file (build-path bin-dir "dumpbin.exe")))
           (and cl lib dumpbin (list cl lib dumpbin))))))

(define (candidate-windows-kit-tool filename)
  (for/or ([root (in-list
                  (filter values
                          (list (getenv "ProgramFiles(x86)")
                                (getenv "ProgramFiles"))))])
    (define bin-root (build-path root "Windows Kits" "10" "bin"))
    (and (directory-exists? bin-root)
         (for/or ([entry (in-list
                          (sort (directory-list bin-root)
                                string>?
                                #:key path->string))])
           (define candidate (build-path bin-root entry "x64" filename))
           (existing-file candidate)))))

(define (discover-windows-toolchain)
  (define vswhere (candidate-vswhere))

  (define path-msbuild (existing-file (find-executable-path "MSBuild.exe")))
  (define path-cl (existing-file (find-executable-path "cl.exe")))
  (define path-lib (existing-file (find-executable-path "lib.exe")))
  (define path-dumpbin (existing-file (find-executable-path "dumpbin.exe")))
  (define path-vc-toolset
    (and path-cl path-lib path-dumpbin
         (list path-cl path-lib path-dumpbin)))

  ;; Resolve the VC installation once, then derive cl/lib/dumpbin from the
  ;; same MSVC toolset. This avoids spawning vswhere once per executable and
  ;; prevents accidentally mixing tools from different MSVC versions.
  (define vc-root
    (and (not path-vc-toolset)
         vswhere
         (vswhere-installation-root
          vswhere
          "Microsoft.VisualStudio.Component.VC.Tools.x86.x64")))
  (define installed-vc-toolset
    (and vc-root (vc-toolset-in-installation vc-root)))
  (define selected-vc-toolset (or path-vc-toolset installed-vc-toolset))

  (define cl
    (if selected-vc-toolset (list-ref selected-vc-toolset 0) path-cl))
  (define lib
    (if selected-vc-toolset (list-ref selected-vc-toolset 1) path-lib))
  (define dumpbin
    (if selected-vc-toolset (list-ref selected-vc-toolset 2) path-dumpbin))

  ;; A Visual Studio installation that contains the VC toolset normally also
  ;; contains MSBuild. Reuse that root before asking vswhere a second time.
  (define msbuild
    (or path-msbuild
        (and vc-root (msbuild-in-installation vc-root))
        (and vswhere
             (let ([msbuild-root
                    (vswhere-installation-root
                     vswhere
                     "Microsoft.Component.MSBuild")])
               (msbuild-in-installation msbuild-root)))))

  (define signtool
    (or (existing-file (find-executable-path "signtool.exe"))
        (candidate-windows-kit-tool "signtool.exe")))

  (windows-toolchain msbuild cl lib dumpbin signtool vswhere))

(module+ test-support
  (provide msbuild-in-installation
           vc-toolset-in-installation
           sorted-child-directories))
