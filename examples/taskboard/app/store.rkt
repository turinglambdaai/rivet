#lang racket/base

;; Optional, versioned on-disk storage for the Taskboard reference project.
;; Normal Taskboard remains session-only until every native host implements
;; and proves the same durable-save interaction. A disposable test profile is
;; selected with RIVET_TASKBOARD_STORE_PATH; no shared developer preferences
;; or packaged resources are overwritten by a test.
(require racket/file
         racket/list
         racket/path
         racket/string)

(provide taskboard-store-path
         read-taskboard-rows
         write-taskboard-rows!)

(define store-tag 'rivet-taskboard-store-v1)
(define maximum-store-bytes (* 16 1024 1024))
(define maximum-store-rows 10000)
(define maximum-int64 (sub1 (expt 2 63)))

(define (taskboard-store-path)
  (define setting (getenv "RIVET_TASKBOARD_STORE_PATH"))
  (and setting
       (not (string=? setting ""))
       (path->complete-path setting)))

;; Each persisted task is (list Int64 String String Symbol), *not* the
;; internal Rivet record/enum representation. This format is portable across
;; Racket versions and can be validated before constructing typed records.
(define (check-rows! who rows)
  (unless (and (list? rows) (<= (length rows) maximum-store-rows))
    (error who "store task count is invalid or exceeds ~a" maximum-store-rows))
  (define ids (make-hasheqv))
  (for ([row (in-list rows)])
    (unless (and (list? row) (= (length row) 4))
      (error who "invalid stored task row"))
    (define id (list-ref row 0))
    (define title (list-ref row 1))
    (define notes (list-ref row 2))
    (define status (list-ref row 3))
    (unless (and (exact-integer? id) (<= 1 id maximum-int64)
                 (not (hash-has-key? ids id)))
      (error who "stored task IDs must be unique positive Int64 values"))
    (hash-set! ids id #t)
    (unless (and (string? title) (not (string=? title ""))
                 (<= (string-length title) 4000)
                 (string=? (string-trim title) title))
      (error who "stored title is invalid"))
    (unless (and (string? notes) (<= (string-length notes) 4000)
                 (string=? (string-trim notes) notes))
      (error who "stored notes are invalid"))
    (unless (memq status '(backlog active done))
      (error who "stored task status is invalid")))
  (void))

(define (read-taskboard-rows path)
  (define target (path->complete-path path))
  (cond
    [(not (file-exists? target)) #f]
    [else
     (when (> (file-size target) maximum-store-bytes)
       (error 'read-taskboard-rows "store exceeds the bounded 16 MiB limit"))
     (define payload
       (call-with-input-file
        target
        (lambda (in)
          (parameterize ([read-accept-reader #f]
                         [read-accept-lang #f]
                         [read-accept-compiled #f]
                         [read-accept-graph #f])
            (define result (read in))
            (unless (eof-object? (read in))
              (error 'read-taskboard-rows "unexpected trailing store data"))
            result))))
     (unless (and (list? payload)
                  (= (length payload) 2)
                  (eq? (car payload) store-tag))
       (error 'read-taskboard-rows "invalid or unsupported store version"))
     (define rows (cadr payload))
     (check-rows! 'read-taskboard-rows rows)
     rows]))

(define (write-taskboard-rows! path rows)
  (check-rows! 'write-taskboard-rows! rows)
  (define target (path->complete-path path))
  (define parent (path-only target))
  (make-directory* parent)
  ;; Write alongside the destination, close fully, then replace it with
  ;; one rename. A failed write leaves the previous complete snapshot alone.
  ;; The atomic rename is not a claim of power-loss fsync durability.
  (define temporary (make-temporary-file "rivet-taskboard-~a.tmp" #f parent))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (call-with-output-file
     temporary
     (lambda (out)
       (write (list store-tag rows) out)
       (newline out)
       (flush-output out))
     #:exists 'truncate)
    (when (> (file-size temporary) maximum-store-bytes)
      (error 'write-taskboard-rows! "store exceeds the bounded 16 MiB limit"))
    (rename-file-or-directory temporary target #t))
  (void))
