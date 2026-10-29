#lang racket/base

;; Product-owned durable snapshot. Native hosts never touch this format and
;; the Rivet transport/schema do not change.
(require racket/file
         racket/list
         racket/match
         racket/path)

(provide task-store-root
         read-task-snapshot
         write-task-snapshot!)

(define snapshot-name "tasks-v1.rktd")
;; Bounds apply to both imports and exports; even a malformed on-disk file
;; cannot force unbounded reader work or become executable Racket source.
(define maximum-snapshot-bytes 400000)
(define maximum-task-count 1000)
(define maximum-task-text 4000)
(define max-id (sub1 (expt 2 63)))

(define (task-store-root)
  (define override (getenv "RIVET_TASKBOARD_DATA_DIR"))
  (if (and override (not (string=? override "")))
      (path->complete-path override)
      (build-path (find-system-path 'pref-dir) "rivet-taskboard")))

(define (snapshot-path root)
  (build-path root snapshot-name))

(define (row-valid? row)
  (match row
    [(list id title notes status)
     (and (exact-integer? id) (<= 1 id max-id)
          (string? title) (<= 1 (string-length title) maximum-task-text)
          (string? notes) (<= (string-length notes) maximum-task-text)
          (memq status '(backlog active done))
          #t)]
    [_ #f]))

(define (validate-snapshot who snapshot)
  (unless (hash? snapshot)
    (error who "invalid task snapshot: expected a versioned hash"))
  (define version (hash-ref snapshot 'version #f))
  (define next-id (hash-ref snapshot 'next-id #f))
  (define rows (hash-ref snapshot 'tasks #f))
  (unless (equal? version 1)
    (error who "unsupported task snapshot version; existing data preserved"))
  (unless (and (list? rows) (<= (length rows) maximum-task-count)
               (andmap row-valid? rows))
    (error who "invalid task snapshot rows; existing data preserved"))
  (define ids (map car rows))
  (unless (and (not (check-duplicates ids))
               (exact-integer? next-id)
               (<= 1 next-id max-id)
               (for/and ([id (in-list ids)]) (< id next-id)))
    (error who "invalid task snapshot IDs; existing data preserved"))
  (vector next-id rows))

(define (read-task-snapshot root)
  (define target (snapshot-path root))
  (cond
    [(not (file-exists? target)) #f]
    [else
     (when (> (file-size target) maximum-snapshot-bytes)
       (error 'read-task-snapshot "task snapshot exceeds safe size limit; existing data preserved"))
     (call-with-input-file target
       (lambda (input)
         (parameterize ([read-accept-reader #f])
           (define value (read input))
           (unless (eof-object? (read input))
             (error 'read-task-snapshot "task snapshot has trailing data; existing data preserved"))
           (validate-snapshot 'read-task-snapshot value))))]))

(define (write-task-snapshot! root next-id rows)
  (define snapshot (hash 'version 1 'next-id next-id 'tasks rows))
  (validate-snapshot 'write-task-snapshot! snapshot)
  (make-directory* root)
  (define target (snapshot-path root))
  ;; Stage beside the destination so rename is within one filesystem. Never
  ;; overwrite the good snapshot until validation and the bounded write pass.
  (define temporary (make-temporary-file "tasks-v1~a.tmp" #f root))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file temporary
        (lambda (output)
          (write snapshot output)
          (newline output)
          (flush-output output))
        #:exists 'truncate)
      (when (> (file-size temporary) maximum-snapshot-bytes)
        (error 'write-task-snapshot! "task snapshot exceeds safe size limit; existing data preserved"))
      (rename-file-or-directory temporary target #t))
    (lambda ()
      (when (file-exists? temporary)
        (delete-file temporary))))
  (void))
