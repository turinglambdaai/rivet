#lang racket/base

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         net/base64
         racket/file
         racket/port
         racket/string)

(provide sha256-bytes
         sha256-file
         sha256-file/hex
         read-ed25519-public-key
         read-ed25519-private-key
         bytes->ed25519-public-key
         ed25519-sign
         ed25519-verify
         bytes->base64-string
         base64-string->bytes)

;; crypto-lib chooses the best available audited provider (OpenSSL, Nettle,
;; libsodium, or Decaf). The manifest pins the algorithm to Ed25519, so a
;; provider that lacks it fails closed instead of falling back to another
;; signature scheme.
;;
;; Rivet's manifest crypto is exactly SHA-256 digests and Ed25519
;; sign/verify, so the provider set is pinned to libcrypto alone: the
;; official Racket distributions bundle OpenSSL on every desktop target.
;; Requiring crypto/all (or instantiating more factories) would drag in
;; factory modules whose FFI loads run at module-import time — the gmp
;; factory kills the process there on hosts without libgmp, and every
;; embedded app that merely verifies a manifest shipped that landmine
;; (found by packaging a real app for macOS, where the CI-built bundle
;; would not start).
(crypto-factories (list libcrypto-factory))

(define ed25519-factories
  (list libcrypto-factory))

(define (bytes->base64-string value)
  (bytes->string/utf-8 (base64-encode value #"")))

(define (base64-string->bytes value)
  (unless (string? value)
    (raise-argument-error 'base64-string->bytes "string?" value))
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (raise-arguments-error 'base64-string->bytes
                                            "invalid base64 value"
                                            "value" value))])
    (base64-decode (string->bytes/utf-8 value))))

(define (sha256-bytes input)
  (digest 'sha256 input))

(define (sha256-file path)
  (call-with-input-file path
    (lambda (in) (digest 'sha256 in))
    #:mode 'binary))

(define (sha256-file/hex path)
  (bytes->hex-string (sha256-file path)))

(define (decode-key who raw formats #:origin [origin #f])
  (or (for/or ([format (in-list formats)])
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (datum->pk-key raw format ed25519-factories)))
      (apply raise-arguments-error who
             "could not decode Ed25519 key"
             (append (list "accepted formats" formats)
                     (if origin (list "path" origin) (list))))))

(define (read-key who path formats)
  (decode-key who (file->bytes path) formats #:origin path))

(define (ensure-ed25519 who key private?)
  (unless (pk-key? key)
    (raise-argument-error who "pk-key?" key))
  (define datum (pk-key->datum key (if private? 'rkt-private 'rkt-public)))
  (unless (and (list? datum)
               (pair? datum)
               (eq? (car datum) 'eddsa)
               (member 'ed25519 datum))
    (raise-arguments-error who "key is not Ed25519" "key" key))
  key)

(define (read-ed25519-public-key path)
  (ensure-ed25519
   'read-ed25519-public-key
   (read-key 'read-ed25519-public-key path
             '(SubjectPublicKeyInfo rkt-public openssh-public))
   #f))

;; Release builds embed the channel's public key as DER hex in app source
;; (the runbook pattern: the private half never lives in a checkout), so
;; the parsed key must be reachable from bytes and not only from a file.
(define (bytes->ed25519-public-key raw)
  (ensure-ed25519
   'bytes->ed25519-public-key
   (decode-key 'bytes->ed25519-public-key raw
               '(SubjectPublicKeyInfo rkt-public openssh-public))
   #f))

(define (read-ed25519-private-key path)
  (ensure-ed25519
   'read-ed25519-private-key
   (read-key 'read-ed25519-private-key path
             '(OneAsymmetricKey PrivateKeyInfo rkt-private))
   #t))

(define (ed25519-sign private-key message)
  (define checked (ensure-ed25519 'ed25519-sign private-key #t))
  (define safe-key
    (datum->pk-key (pk-key->datum checked 'rkt-private)
                   'rkt-private
                   ed25519-factories))
  (pk-sign safe-key message))

(define (ed25519-verify public-key message signature)
  (define checked (ensure-ed25519 'ed25519-verify public-key #f))
  (define safe-key
    (datum->pk-key (pk-key->datum checked 'rkt-public)
                   'rkt-public
                   ed25519-factories))
  (and (= (bytes-length signature) 64)
       (pk-verify safe-key message signature)))
