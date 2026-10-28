#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

;; Native UI and packaged MSI test the icon pixels on both windows; this
;; static gate protects the generated scaffold source on all CI platforms.
;; In particular, a literal backslash-n after a // comment would comment out
;; ApplyAppIcon and leave the default WinUI title bar icon in every new host.
(define-runtime-path source "../../platform/windows/host/MainWindow.xaml.cpp")
(define text (file->string source))

(check-true
 (string-contains? text
                   "// Only titled windows opt in; absent brand resources keep the native default.\n  (void)rivet::system::ApplyAppIcon(*this);\n  // Ordinary window close")
 "the scaffold must apply its embedded icon as executable C++, not comment text")
(check-false
 (string-contains? text "default.\\n  (void)rivet::system::ApplyAppIcon")
 "escaped newline text would silently disable the generated icon call")
