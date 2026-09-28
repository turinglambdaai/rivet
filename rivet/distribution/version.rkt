#lang racket/base

(require racket/list
         racket/match
         racket/string)

(provide version?
         version-compare
         version<?
         version<=?
         version=?
         version>=?
         version>?
         valid-channel?
         channel-accepts-version?)

;; Rivet deliberately implements the precedence portion of SemVer 2.0 here
;; instead of relying on platform package managers. Build metadata never
;; affects precedence; pre-release identifiers follow numeric/alphanumeric
;; ordering from semver.org.
(define version-rx
  #px"^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$")

(define (parse-version value)
  (and (string? value)
       (let ([m (regexp-match version-rx value)])
         (and m
              (let ([prerelease
                     (and (list-ref m 4)
                          (string-split (list-ref m 4) "."))])
                (and (or (not prerelease)
                         (for/and ([part (in-list prerelease)])
                           (not (and (regexp-match? #px"^[0-9]+$" part)
                                     (> (string-length part) 1)
                                     (char=? (string-ref part 0) #\0)))))
                     (list (string->number (list-ref m 1))
                           (string->number (list-ref m 2))
                           (string->number (list-ref m 3))
                           prerelease)))))))

(define (version? value) (and (parse-version value) #t))

(define (identifier-compare a b)
  (define an (string->number a))
  (define bn (string->number b))
  (cond
    [(and an bn) (cond [(< an bn) -1] [(> an bn) 1] [else 0])]
    [an -1]
    [bn 1]
    [(string<? a b) -1]
    [(string>? a b) 1]
    [else 0]))

(define (prerelease-compare a b)
  (cond
    [(and (not a) (not b)) 0]
    [(not a) 1]
    [(not b) -1]
    [else
     (let loop ([left a] [right b])
       (cond
         [(and (null? left) (null? right)) 0]
         [(null? left) -1]
         [(null? right) 1]
         [else
          (define c (identifier-compare (car left) (car right)))
          (if (zero? c)
              (loop (cdr left) (cdr right))
              c)]))]))

(define (version-compare a b)
  (define av (parse-version a))
  (define bv (parse-version b))
  (unless av
    (raise-argument-error 'version-compare "SemVer 2.0 version string" a))
  (unless bv
    (raise-argument-error 'version-compare "SemVer 2.0 version string" b))
  (let loop ([left (take av 3)] [right (take bv 3)])
    (cond
      [(null? left) (prerelease-compare (list-ref av 3) (list-ref bv 3))]
      [(< (car left) (car right)) -1]
      [(> (car left) (car right)) 1]
      [else (loop (cdr left) (cdr right))])))

(define (version<? a b) (= -1 (version-compare a b)))
(define (version<=? a b) (not (= 1 (version-compare a b))))
(define (version=? a b) (zero? (version-compare a b)))
(define (version>=? a b) (not (= -1 (version-compare a b))))
(define (version>? a b) (= 1 (version-compare a b)))

(define (valid-channel? value)
  (memq value '(stable beta dev)))

(define (channel-accepts-version? channel value)
  (unless (valid-channel? channel)
    (raise-argument-error 'channel-accepts-version? "'stable, 'beta, or 'dev" channel))
  (define parsed (parse-version value))
  (unless parsed
    (raise-argument-error 'channel-accepts-version? "SemVer 2.0 version string" value))
  (define prerelease (list-ref parsed 3))
  (case channel
    [(stable) (not prerelease)]
    [(beta)
     (or (not prerelease)
         (for/or ([part (in-list prerelease)])
           (regexp-match? #px"(?i:^beta(?:[.-]|$))" part)))]
    [(dev) #t]))
