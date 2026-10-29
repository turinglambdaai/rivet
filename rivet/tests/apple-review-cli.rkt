#lang racket/base

(require rackunit
         racket/runtime-path
         rivet-cli/apple-review)

(define-runtime-path scanner "../rivet-cli/apple-review-preflight.py")

(check-true (file-exists? scanner)
            "The installed CLI package must ship the Apple scanner.")

(define (parsed args)
  (call-with-values
   (lambda () (parse-apple-review-options args))
   list))

(check-equal?
 (parsed '("--channel" "developer-id" "--app" "dist/demo.app" "--json"))
 (list "developer-id" "dist/demo.app" #t))

(check-equal?
 (parsed '("--json" "--app" "dist/demo.app" "--channel" "mac-app-store"))
 (list "mac-app-store" "dist/demo.app" #t))

(check-equal?
 (parsed '("--channel" "ios-app-store" "--app" "unused"))
 (list "ios-app-store" "unused" #f))

(for ([bad (in-list
            (list '()
                  '("--channel" "developer-id")
                  '("--app" "dist/demo.app")
                  '("--app" "dist/demo.app" "--channel" "unrecognized")
                  '("--channel" "developer-id" "--app" "a" "--json" "--json")
                  '("--channel" "developer-id" "--app" "a" "--unknown")
                  '("--channel" "developer-id" "--app" "a" "--channel" "ios-app-store")))])
  (check-exn exn:fail? (lambda () (parse-apple-review-options bad))))
