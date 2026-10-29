#lang racket/base

(require rackunit
         racket/list
         racket/file
         "../../examples/taskboard/app/store.rkt")

(define root (make-temporary-file "rivet-board-store-tests-~a" 'directory))
(define saved (build-path root "profile-a" "tasks.rktd"))
(define other (build-path root "profile-b" "tasks.rktd"))
(define rows
  (list (list 2 "Edited task" "Sample notes" 'active)
        (list 4 "中文 title" "" 'done)))

(check-false (read-taskboard-rows saved))
(write-taskboard-rows! saved rows)
(check-equal? (read-taskboard-rows saved) rows)
(check-true (file-exists? saved))
(check-false (read-taskboard-rows other))
(write-taskboard-rows! other '())
(check-equal? (read-taskboard-rows other) '())
(check-equal? (read-taskboard-rows saved) rows)

;; Invalid mutations must not modify the last complete file on disk.
(check-exn #rx"unique positive Int64"
           (lambda ()
             (write-taskboard-rows! saved
                                    (list (first rows) (first rows)))))
(check-equal? (read-taskboard-rows saved) rows)
(check-exn #rx"title is invalid"
           (lambda ()
             (write-taskboard-rows! saved
                                    (list (list 8 "  " "" 'done)))))
(check-equal? (read-taskboard-rows saved) rows)
(check-exn #rx"status is invalid"
           (lambda ()
             (write-taskboard-rows! saved
                                    (list (list 8 "Valid" "" 'invented)))))
(check-equal? (read-taskboard-rows saved) rows)

;; A destination that is not a writable file rejects the save without
;; pretending it was successful and without leaving a temp snapshot behind.
(define blocked (build-path root "existing-directory"))
(make-directory blocked)
(check-exn exn:fail?
           (lambda () (write-taskboard-rows! blocked rows)))
(check-true (directory-exists? blocked))

;; Truncated/unknown store versions are never silently reset to sample data.
(call-with-output-file
 saved (lambda (out) (write '(rivet-taskboard-store-v7 ()) out))
 #:exists 'truncate)
(check-exn #rx"invalid or unsupported store version"
           (lambda () (read-taskboard-rows saved)))
(check-true (file-exists? saved))
(call-with-output-file
 saved (lambda (out) (display "(rivet-taskboard-store-v1 ()) bad" out))
 #:exists 'truncate)
(check-exn #rx"trailing store data"
           (lambda () (read-taskboard-rows saved)))
(delete-directory/files root)
