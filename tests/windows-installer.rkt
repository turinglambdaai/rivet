#lang racket/base

(require rackunit
         racket/file
         racket/string
         "../rivet-cli/installer.rkt"
         "../rivet-cli/project.rkt")

;; The generated WiX source must give installed apps a Start Menu entry:
;; an MSI that only drops files into Program Files leaves users digging
;; for RivetHost.exe by hand.

(define root (make-temporary-file "rivet-installer-~a" 'directory))
(define project
  (rivet-project
   root
   (hash 'name "demo"
         'backend "app/backend.rkt"
         'module "backend"
         'entry "start"
         'protocol 1
         'display-name "Demo App"
         'identifier "dev.rivet.demo")))
(define package (build-path root "dist" "demo-windows-x64"))
(make-directory* package)
(define source (build-path root ".rivet" "installer" "product.wxs"))
(make-parent-directory* source)
(write-wix-source! project package source)

(define wxs (file->string source))

(check-true (string-contains? wxs "StandardDirectory Id=\"ProgramMenuFolder\"")
            "the WiX source declares the Start Menu program group")
(check-true (string-contains? wxs "<Shortcut ")
            "the WiX source declares a Start Menu shortcut")
(check-true (string-contains? wxs "Name=\"Demo App\"")
            "the shortcut is named after the display name")
(check-true (string-contains? wxs "Target=\"[INSTALLFOLDER]RivetHost.exe\"")
            "the shortcut launches the packaged host")
(check-true (string-contains? wxs "WorkingDirectory=\"INSTALLFOLDER\"")
            "the shortcut starts in the install folder so the runtime resolves")
(check-true (string-contains? wxs "<RemoveFolder ")
            "the program group is removed again on uninstall")
(check-true (string-contains? wxs "KeyPath=\"yes\"")
            "the shortcut component carries a key path")

;; The shortcut lives inside the ProductComponents group, so the Main
;; feature installs it without a second feature reference.
(check-true
 (regexp-match? #rx"<ComponentGroup Id=\"ProductComponents\"[^>]*>(?s:.*)<Component Id=\"StartMenuShortcut\"" wxs)
 "the shortcut component is part of the product component group")
