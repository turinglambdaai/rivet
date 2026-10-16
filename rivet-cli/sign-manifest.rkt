#lang racket/base

;; Builds the release update manifest from a dist directory, signs it with
;; the distribution signer, and refuses to publish anything unsigned or
;; unverified. Products keep only their asset-naming conventions: each
;; artifact is named explicitly on the command line, and the manifest URL is
;; the base URL joined with the file name.

(require racket/file
         racket/match
         racket/path
         racket/string
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/manifest.rkt")

(provide sign-manifest!
         parse-sign-manifest-arguments
         (struct-out requested-artifact))

(define installer-symbols '(zip msi deb rpm appimage))

(struct requested-artifact (platform architecture installer path) #:transparent)

(define (parse-artifact-spec who spec)
  (define parts (string-split spec ":"))
  (unless (= (length parts) 4)
    (raise-arguments-error who
                           "--artifact expects <platform>:<arch>:<installer>:<file>"
                           "value" spec))
  (define platform (string->symbol (list-ref parts 0)))
  (define architecture (string->symbol (list-ref parts 1)))
  (define installer (string->symbol (list-ref parts 2)))
  (unless (memq platform '(windows macos linux))
    (raise-arguments-error who "artifact platform must be windows, macos, or linux"
                           "value" spec))
  (unless (memq architecture '(x64 arm64))
    (raise-arguments-error who "artifact architecture must be x64 or arm64"
                           "value" spec))
  (unless (memq installer installer-symbols)
    (raise-arguments-error
     who
     "artifact installer must be zip, msi, deb, rpm, or appimage"
     "value" spec))
  (requested-artifact platform architecture installer (list-ref parts 3)))

(define (parse-sign-manifest-arguments arguments)
  (let loop ([remaining arguments]
             [artifacts '()]
             [options (hasheq)])
    (define (with key tail value)
      (if (hash-has-key? options key)
          (raise-arguments-error 'sign-manifest
                                 (format "~a may be specified only once" key))
          (loop tail artifacts (hash-set options key value))))
    (match remaining
      ['()
       (values (reverse artifacts) options)]
      [(list* "--application-id" value tail) (with 'application-id tail value)]
      [(list* "--version" value tail) (with 'version tail value)]
      [(list* "--build" value tail)
       (define number (string->number value))
       (unless number
         (raise-arguments-error 'sign-manifest "--build requires an integer" "value" value))
       (loop tail artifacts (hash-set options 'build number))]
      [(list* "--channel" value tail)
       (unless (memq (string->symbol value) '(stable beta dev))
         (raise-arguments-error 'sign-manifest
                                "--channel must be stable, beta, or dev"
                                "value" value))
       (with 'channel tail (string->symbol value))]
      [(list* "--base-url" value tail)
       (unless (and (string? value) (regexp-match? #px"^https://" value))
         (raise-arguments-error 'sign-manifest
                                "--base-url must be an HTTPS URL"
                                "value" value))
       (with 'base-url tail value)]
      [(list* "--key-id" value tail) (with 'key-id tail value)]
      [(list* "--private-key" value tail) (with 'private-key tail value)]
      [(list* "--public-key" value tail) (with 'public-key tail value)]
      [(list* "--output" value tail) (with 'output tail value)]
      [(list* "--minimum-version" value tail) (with 'minimum-version tail value)]
      [(list* "--previous-version" value tail) (with 'previous-version tail value)]
      [(list* "--published-at" value tail) (with 'published-at tail value)]
      [(list* "--rollout" value tail)
       (define number (string->number value))
       (unless (and number (integer? number) (>= number 0) (<= number 100))
         (raise-arguments-error 'sign-manifest
                                "--rollout requires an integer between 0 and 100"
                                "value" value))
       (loop tail artifacts (hash-set options 'rollout number))]
      [(list "--rollback-allowed") (loop artifacts (hash-set options 'rollback-allowed? #t))]
      [(list "--sidecars") (loop artifacts (hash-set options 'sidecars? #t))]
      [(list* "--artifact" spec tail)
       (loop tail (cons (parse-artifact-spec 'sign-manifest spec) artifacts) options)]
      [(cons argument _)
       (raise-arguments-error 'sign-manifest "unknown argument" "argument" argument)])))

(define (require-option who options key)
  (or (hash-ref options key #f)
      (raise-arguments-error who
                             (format "~a is required" key))))

(define (join-url base-url file-name)
  (format "~a/~a"
          (string-trim base-url "/" #:right? #t)
          file-name))

(define (write-sidecar! artifact-path)
  (define sidecar (path-add-extension artifact-path #".sha256"))
  (call-with-output-file sidecar
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "~a  ~a\n"
               (sha256-file/hex artifact-path)
               (path->string (file-name-from-path artifact-path)))))
  sidecar)

(define (sign-manifest! artifacts options)
  (define application-id (require-option 'sign-manifest options 'application-id))
  (define version (require-option 'sign-manifest options 'version))
  (define build (require-option 'sign-manifest options 'build))
  (define channel (require-option 'sign-manifest options 'channel))
  (define base-url (require-option 'sign-manifest options 'base-url))
  (define key-id (require-option 'sign-manifest options 'key-id))
  (define output
    (string->path
     (or (hash-ref options 'output #f)
         "dist/update-manifest.json")))
  (when (null? artifacts)
    (raise-arguments-error 'sign-manifest
                           "at least one --artifact is required"))
  (define private-key-path
    (or (hash-ref options 'private-key #f)
        (getenv "RIVET_UPDATE_PRIVATE_KEY")
        (raise-arguments-error 'sign-manifest
                               "a private key is required: pass --private-key or set RIVET_UPDATE_PRIVATE_KEY")))
  (define private-key (read-ed25519-private-key private-key-path))
  (define manifest
    (update-manifest
     application-id version build channel
     (or (hash-ref options 'published-at #f)
         (number->string (current-seconds)))
     (hash-ref options 'minimum-version "0.0.0")
     (hash-ref options 'previous-version #f)
     (hash-ref options 'rollback-allowed? #f)
     (hash-ref options 'rollout 100)
     (for/list ([artifact (in-list artifacts)])
       (define path (string->path (requested-artifact-path artifact)))
       (unless (file-exists? path)
         (raise-arguments-error 'sign-manifest
                                "artifact file does not exist"
                                "file" path))
       (update-artifact
        (requested-artifact-platform artifact)
        (requested-artifact-architecture artifact)
        (join-url base-url (path->string (file-name-from-path path)))
        (sha256-file/hex path)
        (file-size path)
        (requested-artifact-installer artifact)
        '()))))
  (make-parent-directory* output)
  (call-with-output-file output
    #:exists 'truncate/replace
    (lambda (out) (write-signed-manifest manifest private-key key-id out)))
  ;; Fail-closed publish: read the written file back and verify the exact
  ;; bytes with the public half when one is available. A failed verification
  ;; deletes the output so an unverified feed cannot be published by accident.
  (define public-key-path
    (or (hash-ref options 'public-key #f)
        (getenv "RIVET_UPDATE_PUBLIC_KEY")))
  (when public-key-path
    (with-handlers ([exn:fail?
                     (lambda (error)
                       (when (file-exists? output) (delete-file output))
                       (raise error))])
      (call-with-input-file output
        (lambda (in)
          (verify-signed-manifest in
                                  (read-ed25519-public-key public-key-path)
                                  #:key-id key-id)))))
  (when (hash-ref options 'sidecars? #f)
    (for ([artifact (in-list artifacts)])
      (write-sidecar! (string->path (requested-artifact-path artifact)))))
  output)
