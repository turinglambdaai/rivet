#lang racket/base

(require json
         racket/file
         racket/port
         racket/string
         rackunit
         "../../rivet-cli/measure.rkt"
         "../../rivet-cli/project.rkt"
         "../../rivet-cli/scaffold.rkt")

;; The measurement surface is the dist/ tree, so the fixtures are plain
;; files standing in for packaged artifacts — no native packaging needed.

(define temp-root (make-temporary-file "rivet-measure-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "measured" temp-root))
    (define project (load-project project-root))
    (define dist (build-path project-root "dist"))
    (make-directory* dist)
    (define (stage-artifact name bytes)
      (call-with-output-file (build-path dist name)
        (lambda (out) (write-bytes (make-bytes bytes 65) out))))
    (stage-artifact "measured-0.1.0-macos.dmg" 3000)
    (stage-artifact "measured-0.1.0-macos-arm64.zip" 1500)
    (stage-artifact "update-stable.json" 40)

    ;; No budgets: every artifact is listed with its byte count and no
    ;; violations exist.
    (define plain (measure-size project))
    (check-equal? (length (hash-ref plain 'artifacts)) 3)
    (check-equal? (hash-ref plain 'violations) '())
    (check-true
     (for/and ([row (in-list (hash-ref plain 'artifacts))])
       (and (exact-positive-integer? (hash-ref row 'bytes))
            (not (hash-ref row 'budget-bytes)))))

    ;; A budget file gates by glob, first match wins.
    (define budget-path (build-path temp-root "budgets.json"))
    (call-with-output-file budget-path
      (lambda (out)
        (write-json
         (hasheq 'rules
                 (list (hasheq 'glob "*.dmg" 'max-bytes 2000)
                       (hasheq 'glob "*" 'max-bytes 100000)))
         out)))
    (define gated (measure-size project #:budget-path budget-path))
    (check-equal? (length (hash-ref gated 'violations)) 1)
    (define violation (car (hash-ref gated 'violations)))
    (check-true
     (string-suffix?
      (path->string (car violation)) "measured-0.1.0-macos.dmg"))
    (check-equal? (cdr violation) (cons 3000 2000))

    ;; A tight global budget flags everything; relaxing it clears the gate.
    (call-with-output-file budget-path
      #:exists 'truncate
      (lambda (out)
        (write-json
         (hasheq 'rules (list (hasheq 'glob "*" 'max-bytes 200000)))
         out)))
    (check-equal? (hash-ref (measure-size project #:budget-path budget-path)
                            'violations)
                  '())

    ;; A clean budget file without dist artifacts is an error, not an
    ;; empty pass: measuring nothing would read as a green gate.
    (define empty-root (build-path temp-root "empty"))
    (make-directory* empty-root)
    (call-with-output-file (build-path empty-root "rivet.rktd")
      (lambda (out)
        (displayln
         "#hasheq((name . \"Empty\") (backend . \"app/backend.rkt\") (module . \"backend\") (entry . \"start\") (protocol . 1))"
         out)))
    (check-exn #rx"no packaged artifacts"
               (lambda () (measure-size (load-project empty-root))))

    ;; Malformed budget files fail loudly instead of gating nothing.
    (define malformed (build-path temp-root "malformed.json"))
    (call-with-output-file malformed
      (lambda (out) (display "{\"rules\": [{\"glob\": \"*.dmg\"}]}" out)))
    (check-exn #rx"must contain"
               (lambda () (parse-budget-file malformed)))
    (check-exn #rx"budget file .* does not exist"
               (lambda () (parse-budget-file
                           (build-path temp-root "absent.json"))))

    ;; The artifact filter narrows a single row.
    (define filtered
      (measure-size project #:artifact "update-stable.json"))
    (check-equal? (length (hash-ref filtered 'artifacts)) 1)
    (check-equal?
     (hash-ref (car (hash-ref filtered 'artifacts)) 'bytes)
     40))

  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
