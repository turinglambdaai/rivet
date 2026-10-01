#lang racket/base

(require crypto
         crypto/all
         rackunit
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "../rivet/distribution/crypto.rkt"
         "../rivet-cli/installer.rkt"
         "../rivet-cli/linux-package.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/signing-options.rkt"
         "../rivet-cli/tar.rkt"
         "../rivet-cli/verify.rkt")

(use-all-factories!)

(define posix-permissions? (not (eq? (system-type 'os) 'windows)))

(define (nul-terminated raw)
  (define end
    (for/or ([byte (in-bytes raw)] [index (in-naturals)]
             #:when (zero? byte))
      index))
  (subbytes raw 0 (or end (bytes-length raw))))

(define (header-name header)
  (define name (bytes->string/utf-8 (nul-terminated (subbytes header 0 100))))
  (define prefix
    (bytes->string/utf-8 (nul-terminated (subbytes header 345 500))))
  (if (zero? (string-length prefix))
      name
      (string-append prefix "/" name)))

(define (archive-entry-names archive)
  ;; Walk ustar headers to recover the recorded entry order.
  (define (entry-payload-span header)
    (define size
      (string->number
       (string-trim (bytes->string/latin-1 (subbytes header 124 135)))
       8))
    (if (= (bytes-ref header 156) (char->integer #\0))
        (+ size (- 512 (remainder size 512)))
        0))
  (let loop ([offset 0] [names '()])
    (define header (subbytes archive offset (+ offset 512)))
    (cond
      [(for/and ([byte (in-bytes header)]) (zero? byte))
       (reverse names)]
      [else
       (loop (+ offset 512 (entry-payload-span header))
             (cons (header-name header) names))])))

;; ---------------------------------------------------------------------------
;; Deterministic ustar archives

(define package-root (make-temporary-file "rivet-linux-package-~a" 'directory))
(define package
  (build-path package-root
              (string-append "Smoke-linux-" (linux-architecture))))

(define (write-package-file relative content #:exec? [exec? #f])
  (define path (build-path package relative))
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display content out)))
  ;; Windows cannot represent a Unix executable mode. The Linux and macOS
  ;; runners still exercise mode capture and extraction; Windows exercises
  ;; the host-independent ustar layout and deterministic gzip bytes.
  (when (and exec? posix-permissions?)
    (file-or-directory-permissions path #o755)))

(write-package-file "RivetHost" "fake-elf" #:exec? #t)
(write-package-file "res/core.zo" "compiled-backend")
(write-package-file "runtime/petite.boot" "petite")
(write-package-file "runtime/scheme.boot" "scheme")
(write-package-file "runtime/racket.boot" "racket")
(write-package-file
 "app/rivet-app-info.rktd"
 "#hasheq((name . \"Smoke\") (display-name . \"Smoke\") (version . \"0.1.0\") (build . 1) (identifier . \"dev.rivet.smoke\") (release-channel . stable))\n")
(write-package-file "app/assets/nested/product.txt" "packaged-resource")
;; Exercise the ustar prefix field with a name beyond the 100-byte limit.
(write-package-file
 (string-append
  "app/assets/nested/really-deep-directory-chain/repeat-a/repeat-b/repeat-c/"
  "repeat-d/repeat-e/repeat-f/repeat-g/repeat-h/repeat-i/long-name-file.txt")
 "deep")

(define raw-archive (tar-directory->bytes package))
(check-equal? (tar-directory->bytes package) raw-archive
              "two archives of the same directory must be byte-identical")
(check-equal? (subbytes raw-archive 257 263) #"ustar\0"
              "archive headers must carry the ustar magic")
(check-equal? (subbytes raw-archive 136 147) #"00000000000"
              "archive headers pin modification times to the epoch")
(check-equal? (subbytes (gzip-archive-bytes raw-archive) 0 2) #"\x1f\x8b"
              "the installer payload must be a gzip container")
(check-equal? (gzip-archive-bytes raw-archive)
              (gzip-archive-bytes (tar-directory->bytes package))
              "the gzip container must be byte-identical across runs")

;; Entry names are deterministic and sorted: parents precede their contents.
(define entry-names (archive-entry-names raw-archive))
(check-equal? entry-names (sort entry-names string<?)
              "archive entries must be sorted by name")
(check-true (< (index-of entry-names "res")
               (index-of entry-names "res/core.zo"))
            "directory entries must precede their contents")
(check-true
 (and (member
       (string-append
        "app/assets/nested/really-deep-directory-chain/repeat-a/repeat-b/"
        "repeat-c/repeat-d/repeat-e/repeat-f/repeat-g/repeat-h/repeat-i/"
        "long-name-file.txt")
       entry-names)
      #t)
 "the ustar prefix field must carry names beyond the 100-byte limit")

(when (find-executable-path "tar")
  (define extract-root
    (make-temporary-file "rivet-linux-extract-~a" 'directory))
  (define archive-path (build-path extract-root "installer.tar.gz"))
  (call-with-output-file archive-path
    #:exists 'truncate/replace
    (lambda (out)
      (write-bytes
       (gzip-archive-bytes
        (tar-directory->bytes
         package
         #:root-name (path->string (file-name-from-path package))))
       out)))
  (define extracted?
    (parameterize ([current-directory extract-root])
      (system* (find-executable-path "tar") "-xzf" "installer.tar.gz")))
  (check-true extracted? "system tar must accept the ustar archive")
  (when extracted?
    (define extracted (build-path extract-root (file-name-from-path package)))
    (check-equal?
     (file->string (build-path extracted "res" "core.zo"))
     "compiled-backend")
    (check-equal?
     (file->string
      (build-path extracted "app" "assets" "nested" "product.txt"))
     "packaged-resource")
    (check-equal?
     (file->string
      (build-path
       extracted
       "app/assets/nested/really-deep-directory-chain/repeat-a/repeat-b/repeat-c/"
       "repeat-d/repeat-e/repeat-f/repeat-g/repeat-h/repeat-i/long-name-file.txt"))
     "deep")
    (when posix-permissions?
      (define bits
        (file-or-directory-permissions (build-path extracted "RivetHost") 'bits))
      (check-true
       (if (list? bits)
           (if (memq 'execute bits) #t #f)
           (positive? (bitwise-and bits #o111)))
       "the packaged executable must keep its executable mode"))))

;; ---------------------------------------------------------------------------
;; Linux production signing options

(define signing-vars
  '(#"RIVET_LINUX_SIGN_PRIVATE_KEY"
    #"RIVET_LINUX_SIGN_KEY_ID"
    #"RIVET_LINUX_SIGN_PUBLIC_KEY"))

(define (with-linux-signing-env entries thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([name (in-list signing-vars)])
    (environment-variables-set! env name #f))
  (for ([entry (in-list entries)])
    (environment-variables-set! env (car entry) (cdr entry)))
  (parameterize ([current-environment-variables env])
    (thunk)))

(check-exn
 #rx"RIVET_LINUX_SIGN_PRIVATE_KEY"
 (lambda ()
   (with-linux-signing-env '() load-linux-production-signing)))

(check-exn
 #rx"RIVET_LINUX_SIGN_PUBLIC_KEY"
 (lambda ()
   (with-linux-signing-env '() load-linux-production-verification)))

;; ---------------------------------------------------------------------------
;; Installer creation and production verification (Linux host required)

(when (eq? (system-type 'os) 'unix)
  (define project (rivet-project package-root (hasheq 'name "Smoke")))
  (define installer (create-installer! project package))
  (check-equal?
   (file-name-from-path installer)
   (string->path (format "Smoke-0.1.0-linux-~a.tar.gz" (linux-architecture))))
  (check-true (file-exists? installer))
  (check-false
   (file-exists? (string-append (path->string installer) ".sig"))
   "development installers are not signed")

  (define ed25519-impl
    (get-pk 'eddsa (list libcrypto-factory sodium-factory decaf-factory)))
  (define private-key
    (and ed25519-impl
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (generate-private-key ed25519-impl '((curve ed25519))))))
  (unless private-key
    (printf
     "Rivet Linux installer tests: compatible Ed25519 provider unavailable; production signing is covered where a provider exists\n"))

  (when private-key
    (define private-key-path
      (make-temporary-file "rivet-linux-update-private-~a.der"))
    (define public-key-path
      (make-temporary-file "rivet-linux-update-public-~a.der"))
    (call-with-output-file private-key-path
      #:exists 'truncate/replace
      (lambda (out)
        (write-bytes (pk-key->datum private-key 'PrivateKeyInfo) out)))
    (call-with-output-file public-key-path
      #:exists 'truncate/replace
      (lambda (out)
        (write-bytes (pk-key->datum private-key 'SubjectPublicKeyInfo) out)))

    (define (with-production-env thunk)
      (with-linux-signing-env
       (list (cons #"RIVET_LINUX_SIGN_PRIVATE_KEY"
                   (path->bytes private-key-path))
             (cons #"RIVET_LINUX_SIGN_KEY_ID" #"release-2026")
             (cons #"RIVET_LINUX_SIGN_PUBLIC_KEY"
                   (path->bytes public-key-path)))
       thunk))

    ;; Production verification runs ldd on the packaged executable, so it
    ;; must be a real ELF before the installer is signed.
    (define sh (find-executable-path "sh"))
    (when sh
      (copy-file sh (build-path package "RivetHost") #t)
      (file-or-directory-permissions (build-path package "RivetHost") #o755)

      (define signed
        (with-production-env
         (lambda ()
           (create-installer! project package #:production? #t))))
      (define signature-path (string-append (path->string signed) ".sig"))
      (check-true (file-exists? signature-path)
                  "production installers must carry a detached signature")

      (check-equal?
       (with-production-env
        (lambda ()
          (verify-package! project package #:production? #t)))
       package)

      ;; Re-creating the installer over an untouched package is byte-stable,
      ;; including the signature.
      (define signature-before (file->bytes signature-path))
      (with-production-env
       (lambda ()
         (create-installer! project package #:production? #t)))
      (check-equal? (file->bytes signature-path) signature-before
                    "production signing must be deterministic")

      ;; A mutated package must invalidate the released archive.
      (write-package-file "app/assets/nested/product.txt" "tampered")
      (check-exn
       #rx"does not match the packaged directory"
       (lambda ()
         (with-production-env
          (lambda ()
            (verify-package! project package #:production? #t)))))
      (write-package-file "app/assets/nested/product.txt" "packaged-resource")

      ;; A corrupted signature must fail Ed25519 verification.
      (call-with-output-file signature-path
        #:exists 'truncate/replace
        (lambda (out)
          (displayln
           (bytes->base64-string (make-bytes 64 255))
           out)))
      (check-exn
       #rx"Ed25519 signature does not verify"
       (lambda ()
         (with-production-env
          (lambda ()
            (verify-package! project package #:production? #t))))))

    (delete-file private-key-path)
    (delete-file public-key-path))

  (delete-directory/files package-root))
