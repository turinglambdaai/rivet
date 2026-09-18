#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system)

(provide (struct-out windows-toolchain)
         discover-windows-toolchain)

(struct windows-toolchain (msbuild cl lib vswhere) #:transparent)

(define (existing-file path)
  (and path (file-exists? path) (simplify-path path #t)))

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

(define (first-existing-line text)
  (and text
       (for/or ([line (in-list (string-split text "\n"))])
         (define candidate (string-trim line))
         (and (not (string=? candidate ""))
              (existing-file (string->path candidate))))))

(define (vswhere-find vswhere component pattern)
  (first-existing-line
   (capture-command
    vswhere
    (list "-latest"
          "-products" "*"
          "-requires" component
          "-find" pattern))))

(define (discover-windows-toolchain)
  (define vswhere (candidate-vswhere))

  (define msbuild
    (or (existing-file (find-executable-path "MSBuild.exe"))
        (and vswhere
             (vswhere-find
              vswhere
              "Microsoft.Component.MSBuild"
              "MSBuild\\**\\Bin\\MSBuild.exe"))))

  (define cl
    (or (existing-file (find-executable-path "cl.exe"))
        (and vswhere
             (vswhere-find
              vswhere
              "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
              "VC\\Tools\\MSVC\\**\\bin\\Hostx64\\x64\\cl.exe"))))

  (define lib
    (or (existing-file (find-executable-path "lib.exe"))
        (and vswhere
             (vswhere-find
              vswhere
              "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
              "VC\\Tools\\MSVC\\**\\bin\\Hostx64\\x64\\lib.exe"))))

  (windows-toolchain msbuild cl lib vswhere))
