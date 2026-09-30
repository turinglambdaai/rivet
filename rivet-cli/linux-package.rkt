#lang racket/base

(require "project.rkt")

(provide linux-architecture
         linux-package-directory-name
         linux-installer-path)

;; Shared Linux packaging names. Kept as a leaf module so the packager, the
;; installer, and the verifier agree on one layout without a require cycle.

(define (linux-architecture)
  (case (system-type 'arch)
    [(aarch64 arm64) "arm64"]
    [(x86_64) "x64"]
    [else (format "~a" (system-type 'arch))]))

(define (linux-package-directory-name project)
  (string-append (project-name project) "-linux-" (linux-architecture)))

(define (linux-installer-path project)
  (project-path project "dist"
                (format "~a-~a-linux-~a.tar.gz"
                        (project-name project)
                        (project-version project)
                        (linux-architecture))))
