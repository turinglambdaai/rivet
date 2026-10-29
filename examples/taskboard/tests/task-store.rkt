#lang racket/base

(require rackunit
         racket/file
         "../app/task-store.rkt")

(define root (make-temporary-file "rivet-taskboard-store~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (check-false (read-task-snapshot root))
    (define tasks (list (list 1 "Draft that survives restart" "" 'active)
                        (list 2 "Task two" "notes" 'done)))
    (write-task-snapshot! root 3 tasks)
    (define restored (read-task-snapshot root))
    (check-equal? (vector-ref restored 0) 3)
    (check-equal? (vector-ref restored 1) tasks)

    ;; A completed save replaces the previous snapshot as a whole.
    (define changed (list (list 1 "Saved" "unchanged notes" 'done)))
    (write-task-snapshot! root 4 changed)
    (check-equal? (vector-ref (read-task-snapshot root) 1) changed)

    ;; Invalid updates must not overwrite the last known good snapshot.
    (check-exn exn:fail?
               (lambda () (write-task-snapshot! root 4
                 (list (list 1 "" "empty title" 'active)))))
    (check-exn exn:fail?
               (lambda () (write-task-snapshot! root 4
                 (list (list 1 "a" "" 'active)
                       (list 1 "duplicate" "" 'done)))))
    (check-equal? (vector-ref (read-task-snapshot root) 1) changed)

    ;; A directory failure is propagated; do not report a successful save.
    (define not-a-directory (build-path root "a-file"))
    (call-with-output-file not-a-directory
      (lambda (out) (display "not a directory" out)))
    (check-exn exn:fail?
               (lambda () (write-task-snapshot! not-a-directory 5 changed)))
    (check-equal? (vector-ref (read-task-snapshot root) 1) changed)

    ;; Corrupt or future-format data must fail closed instead of silently
    ;; resetting user tasks to the packaged demonstration defaults.
    (define snapshot (build-path root "tasks-v1.rktd"))
    (call-with-output-file snapshot
      (lambda (out) (display "#hash((version . 999) (next-id . 1) (tasks . ()))" out))
      #:exists 'truncate)
    (check-exn exn:fail? (lambda () (read-task-snapshot root)))
    (call-with-output-file snapshot
      (lambda (out) (display "#hash((version . 1) (next-id . 2) (tasks . ((1 \"ok\" \"\" active)))) trailing" out))
      #:exists 'truncate)
    (check-exn exn:fail? (lambda () (read-task-snapshot root))))
  (lambda () (delete-directory/files root)))
