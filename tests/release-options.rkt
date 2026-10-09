#lang racket/base

(require rackunit
         "../rivet-cli/release.rkt")

(define update-variable-names
  '("RIVET_UPDATE_BASE_URL"
    "RIVET_UPDATE_PRIVATE_KEY"
    "RIVET_UPDATE_KEY_ID"))

(define (without-update-environment thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([name (in-list update-variable-names)])
    (environment-variables-set! env (string->bytes/utf-8 name) #f))
  (parameterize ([current-environment-variables env])
    (thunk)))

(without-update-environment
 (lambda ()
   (check-false (release-update-environment #f))
   (check-exn #rx"RIVET_UPDATE_BASE_URL"
              (lambda () (release-update-environment #t)))))

(define complete-env
  (environment-variables-copy (current-environment-variables)))
(environment-variables-set! complete-env
                            #"RIVET_UPDATE_BASE_URL"
                            #"https://downloads.example.test/app/")
(environment-variables-set! complete-env
                            #"RIVET_UPDATE_PRIVATE_KEY"
                            #"keys/update.der")
(environment-variables-set! complete-env
                            #"RIVET_UPDATE_KEY_ID"
                            #"release-2026")
(parameterize ([current-environment-variables complete-env])
  (check-not-false (release-update-environment #t)))
