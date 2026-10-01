#lang racket/base

(require "resources.rkt")

(provide (struct-out app-info)
         current-app-info
         app-name
         app-display-name
         app-version
         app-build
         app-identifier
         app-release-channel)

(struct app-info (name display-name version build identifier release-channel)
  #:transparent)

(define metadata-file-name "rivet-app-info.rktd")

(define (invalid-metadata path message value)
  (raise-arguments-error 'current-app-info
                         message
                         "file" path
                         "value" value))

(define (required-field metadata path key predicate expected)
  (define value
    (hash-ref metadata
              key
              (lambda ()
                (invalid-metadata path
                                  "staged application metadata is missing a required field"
                                  key))))
  (unless (predicate value)
    (invalid-metadata
     path
     (format "staged application metadata field ~a must be ~a" key expected)
     value))
  value)

(define (current-app-info)
  (define path (resource-path metadata-file-name))
  (define-values (metadata trailing)
    (call-with-input-file
     path
     (lambda (in)
       (values (read in) (read in)))))
  (unless (eof-object? trailing)
    (invalid-metadata path "staged application metadata contains trailing data" trailing))
  (unless (hash? metadata)
    (invalid-metadata path "staged application metadata must be a hash" metadata))
  (define non-empty-string?
    (lambda (value) (and (string? value) (positive? (string-length value)))))
  (define release-channel?
    (lambda (value) (memq value '(stable beta dev))))
  (app-info
   (required-field metadata path 'name non-empty-string? "a non-empty string")
   (required-field metadata path 'display-name non-empty-string? "a non-empty string")
   (required-field metadata path 'version non-empty-string? "a non-empty string")
   (required-field metadata path 'build exact-positive-integer? "a positive integer")
   (required-field metadata path 'identifier non-empty-string? "a non-empty string")
   (required-field metadata path 'release-channel release-channel? "stable, beta, or dev")))

(define (app-name) (app-info-name (current-app-info)))
(define (app-display-name) (app-info-display-name (current-app-info)))
(define (app-version) (app-info-version (current-app-info)))
(define (app-build) (app-info-build (current-app-info)))
(define (app-identifier) (app-info-identifier (current-app-info)))
(define (app-release-channel) (app-info-release-channel (current-app-info)))
