#lang racket/base

;; Tolerant ambient logging for the CLI (issue #339). When the ambient
;; log transport dies — the hosted CI log pipe among them — a plain
;; `printf` from the CLI raises `error writing to stream port`
;; (win_err=998) and fails the command even though the tool it ran
;; completed successfully. Wrapping the command dispatch in these ports
;; degrades lost transport to dropped output instead: the child's exit
;; code stays the only success signal.

(require racket/base)

(provide call-with-tolerant-logging
         tolerant-output-port)

;; A port that delegates to `base`, treating a failed write as a
;; completed one (the bytes are dropped, not delivered).
(define (tolerant-output-port base)
  (make-output-port
   'tolerant-log always-evt
   (lambda (bytes start end non-block? enable-break?)
     (with-handlers ([exn:fail? (lambda (_) (- end start))])
       (write-bytes bytes base start end)))
   (lambda ()
     (with-handlers ([exn:fail? void])
       (close-output-port base)))))

(define (call-with-tolerant-logging thunk)
  (define out (tolerant-output-port (current-output-port)))
  (define err (tolerant-output-port (current-error-port)))
  (parameterize ([current-output-port out]
                 [current-error-port err])
    (thunk)))
