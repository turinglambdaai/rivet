#lang racket/base

;; Test-support helpers for Rivet application backends. This module is for
;; test suites only — it never enters an embedded application payload — and
;; answers the two needs every backend test hits: a local HTTP listener on
;; a verifiable ephemeral port, and a tiny request-capture fake.

(require racket/match
         racket/port
         racket/string
         racket/tcp)

(provide ephemeral-http-listener
         (struct-out fake-request)
         serve-http!)

;; racket/tcp cannot report the bound port of a listener, so binding a
;; known-free port requires either a fixed range (breaks under parallel CI)
;; or probing. This helper probes once and returns two values — the concrete
;; port and the listener — failing only when the whole range is exhausted.
(define (ephemeral-http-listener
         [first-port 18432]
         [count 512]
         #:backlog [backlog 16]
         #:host [host "127.0.0.1"])
  (let probe ([candidate first-port])
    (cond
      [(>= candidate (+ first-port count))
       (raise-arguments-error
        'ephemeral-http-listener
        "no free port found in the probe range"
        "first-port" first-port
        "count" count)]
      [else
       (with-handlers ([exn:fail? (lambda (e) (probe (add1 candidate)))])
         (values candidate (tcp-listen candidate backlog #t host)))])))

(struct fake-request (method path headers body) #:transparent)

;; Minimal sequential HTTP/1.1 fake for tests: accepts one connection at a
;; time, parses the request line, headers, and a declared Content-Length
;; body, hands a fake-request to `handler`, and writes back
;; (cons status-line response-bytes) with Connection: close. Run it on a
;; thread; killing the thread stops the fake.
(define (serve-http! listener handler)
  (define (read-header-line in)
    (define raw (read-line in 'return-linefeed))
    (if (eof-object? raw) "" raw))
  (let accept ()
    (define-values (in out) (tcp-accept listener))
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (file-stream-buffer-mode out 'none)
      (define request-line (read-header-line in))
      (match (regexp-match #px"^(\\S+) (\\S+) HTTP/" request-line)
        [#f (void)]
        [(list _ method path)
         (define headers
           (let loop ()
             (define header-line (string-trim (read-header-line in)))
             (if (string=? header-line "")
                 '()
                 (cons (match (regexp-match #px"^([^:]+): (.*)$" header-line)
                         [(list _ name value)
                          (cons (string-trim name) (string-trim value))]
                         [_ (cons header-line "")])
                       (loop)))))
         (define content-length
           (or (for/or ([header (in-list headers)])
                 (and (string-ci=? (car header) "content-length")
                      (string->number (cdr header))))
               0))
         (define body (read-bytes content-length in))
         (define response
           (handler (fake-request (string->symbol (string-upcase method))
                                  path headers body)))
         (display
          (format "HTTP/1.1 ~a\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
                  (car response)
                  (bytes-length (cdr response)))
          out)
         (write-bytes (cdr response) out)
         (flush-output out)
         ;; Give the client a beat to consume the response: a loopback
         ;; Windows close can race the reader with an RST even after the
         ;; bytes were written. A test fake favors reliability over the
         ;; last millisecond.
         (sleep 0.25)
         (close-output-port out)])
      (close-input-port in))
    (accept)))
