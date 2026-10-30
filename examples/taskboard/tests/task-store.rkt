#lang racket/base

(require rackunit
         racket/file
         "../app/task-store.rkt")

(define root (make-temporary-file "rivet-taskboard-store~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define tasks (list (list 1 "Draft that survives restart" "" 'active)
                        (list 2 "Task two" "notes" 'done)))
    (define changed (list (list 1 "Saved" "unchanged notes" 'done)))
    (define not-a-directory (build-path root "a-file"))
    (define snapshot (build-path root "tasks-v1.rktd"))
    (check-false (read-task-snapshot root))
    (write-task-snapshot! root 3 tasks)
    (define restored (read-task-snapshot root))
    (check-equal? (vector-ref restored 0) 3)
    (check-equal? (vector-ref restored 1) tasks)

    ;; A completed save replaces the previous snapshot as a whole.
    (write-task-snapshot! root 4 changed)
    (check-equal? (vector-ref (read-task-snapshot root) 1) changed)

    ;; A product-valid 1,000-task board with meaningful notes must remain
    ;; persistable. The old 400 KB snapshot cap rejected this *valid* input,
    ;; even though each row satisfied the public 4,000-character limit.
    (define large-board
      (for/list ([id (in-range 1 1001)])
        (list id (format "Task ~a" id) (make-string 1024 #\x) 'backlog)))
    (write-task-snapshot! root 1001 large-board)
    (define large-restored (read-task-snapshot root))
    (check-equal? (vector-ref large-restored 0) 1001)
    (check-equal? (length (vector-ref large-restored 1)) 1000)
    (check-equal? (vector-ref large-restored 1) large-board)
    (write-task-snapshot! root 4 changed)

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
    (call-with-output-file not-a-directory
      (lambda (out) (display "not a directory" out)))
    (check-exn exn:fail?
               (lambda () (write-task-snapshot! not-a-directory 5 changed)))
    (check-equal? (vector-ref (read-task-snapshot root) 1) changed)

    ;; Corrupt or future-format data must fail closed instead of silently
    ;; resetting user tasks to the packaged demonstration defaults.
    (call-with-output-file snapshot
      (lambda (out) (display "#hash((version . 999) (next-id . 1) (tasks . ()))" out))
      #:exists 'truncate)
    (check-exn exn:fail? (lambda () (read-task-snapshot root)))
    (call-with-output-file snapshot
      (lambda (out) (display "#hash((version . 1) (next-id . 2) (tasks . ((1 \"ok\" \"\" active)))) trailing" out))
      #:exists 'truncate)
    (check-exn exn:fail? (lambda () (read-task-snapshot root))))
  (lambda () (delete-directory/files root)))
