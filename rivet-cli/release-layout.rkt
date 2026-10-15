#lang racket/base

(require "../rivet/distribution/identity.rkt"
         "project.rkt")

(provide release-platform
         release-architecture
         portable-zip-path)

(define (release-platform)
  (platform-symbol))

(define (release-architecture)
  (architecture-symbol))

(define (portable-zip-path project)
  (project-path
   project "dist"
   (format "~a-~a-~a-~a.zip"
           (project-name project)
           (project-version project)
           (release-platform)
           (release-architecture))))
