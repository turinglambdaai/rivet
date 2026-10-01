#lang racket/base

(require racket/path
         racket/port
         racket/string
         racket/system)

(provide gui-session-available?
         launch-smoke!)

(define maximum-captured-output-bytes (* 64 1024))

(define (non-empty-environment-variable? name)
  (define value (getenv name))
  (and value (not (string=? (string-trim value) ""))))

(define (macos-console-session-available?)
  (define stat (find-executable-path "stat"))
  (define user (or (getenv "USER") (getenv "LOGNAME")))
  (and stat
       user
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define out (open-output-string))
         (define err (open-output-string))
         (define ok?
           (parameterize ([current-output-port out]
                          [current-error-port err])
             (system* stat "-f" "%Su" "/dev/console")))
         (and ok?
              (string=? (string-trim (get-output-string out)) user)))))

(define (gui-session-available?)
  (case (system-type 'os)
    [(windows)
     ;; Interactive Windows shells commonly omit SESSIONNAME. The Services
     ;; session is the one known non-interactive value and cannot host WinUI.
     (define session-name (or (getenv "SESSIONNAME") ""))
     (not (regexp-match? #px"(?i:^service)" session-name))]
    [(macosx) (macos-console-session-available?)]
    [(unix)
     (or (non-empty-environment-variable? "DISPLAY")
         (non-empty-environment-variable? "WAYLAND_DISPLAY"))]
    [else #f]))

(define (capture-port! port result)
  (define chunks '())
  (define captured 0)
  (define truncated? #f)
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (set-box! result
                    (cons (string->bytes/utf-8
                           (string-append "output capture failed: "
                                          (exn-message error)))
                          #f)))])
    (let loop ()
      (define chunk (read-bytes 4096 port))
      (unless (eof-object? chunk)
        (define remaining (- maximum-captured-output-bytes captured))
        (define keep (min remaining (bytes-length chunk)))
        (when (positive? keep)
          (set! chunks (cons (subbytes chunk 0 keep) chunks))
          (set! captured (+ captured keep)))
        (when (< keep (bytes-length chunk))
          (set! truncated? #t))
        ;; Continue draining after the capture bound so a noisy child cannot
        ;; fill its pipe and appear healthy only because it is blocked.
        (loop)))
    (set-box! result
              (cons (apply bytes-append (reverse chunks)) truncated?)))
  (close-input-port port))

(define (captured-output->string result)
  (define raw (car (unbox result)))
  (define text (bytes->string/utf-8 raw #\uFFFD))
  (if (cdr (unbox result))
      (string-append "[output truncated at 65536 bytes]\n" text)
      text))

(define (launch-smoke! executable
                       #:arguments [arguments '()]
                       #:working-directory
                       [working-directory (find-system-path 'temp-dir)]
                       #:seconds [seconds 5.0]
                       #:who [who 'verify-package!])
  (unless (and (real? seconds) (positive? seconds))
    (raise-argument-error 'launch-smoke! "positive real?" seconds))
  (unless (and (list? arguments)
               (andmap path-string? arguments))
    (raise-argument-error 'launch-smoke! "(listof path-string?)" arguments))

  (define executable-path
    (simplify-path (path->complete-path executable) #t))
  (define smoke-directory
    (simplify-path (path->complete-path working-directory) #t))
  (define process #f)
  (define stdout-thread #f)
  (define stderr-thread #f)
  (define stdout-result (box (cons #"" #f)))
  (define stderr-result (box (cons #"" #f)))

  (define (finish-process!)
    (when process
      (when (eq? (subprocess-status process) 'running)
        (with-handlers ([exn:fail? void])
          (subprocess-kill process #t)))
      (subprocess-wait process))
    (when stdout-thread (thread-wait stdout-thread))
    (when stderr-thread (thread-wait stderr-thread)))

  (with-handlers
      ([exn:fail?
        (lambda (error)
          (finish-process!)
          (raise error))])
    (define-values (child child-stdout child-stdin child-stderr)
      (parameterize ([current-directory smoke-directory])
        (apply subprocess #f #f #f executable-path arguments)))
    (set! process child)
    (close-output-port child-stdin)
    (set! stdout-thread
          (thread (lambda () (capture-port! child-stdout stdout-result))))
    (set! stderr-thread
          (thread (lambda () (capture-port! child-stderr stderr-result))))

    (define exited (sync/timeout seconds process))
    (cond
      [exited
       (finish-process!)
       (raise-arguments-error
        who
        "packaged application exited during launch smoke test"
        "executable" executable-path
        "working-directory" smoke-directory
        "required-survival-seconds" seconds
        "exit-status" (subprocess-status process)
        "stderr" (captured-output->string stderr-result)
        "stdout" (captured-output->string stdout-result))]
      [else
       (finish-process!)
       (void)])))
