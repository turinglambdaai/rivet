#lang racket/base

(require "project.rkt")

(provide release-platform
         release-architecture
         portable-zip-path)

(define (release-platform)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]))

(define (release-architecture)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

(define (portable-zip-path project)
  (project-path
   project "dist"
   (format "~a-~a-~a-~a.zip"
           (project-name project)
           (project-version project)
           (release-platform)
           (release-architecture))))
