#lang racket/base

(require rackunit
         racket/port
         racket/string
         racket/tcp
         "../rivet/testing.rkt")

(define (http-get port path)
  (define-values (in out) (tcp-connect "127.0.0.1" port))
  (display (format "GET ~a HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" path) out)
  (close-output-port out)
  ;; The fake closes eagerly; a Windows loopback close can surface as RST on
  ;; a read even after the bytes arrived, so collect what landed and stop on
  ;; error/eof — the assertions below only need the response content.
  (define collected
    (with-handlers ([exn:fail? (lambda (e) '())])
      (let loop ()
        (define chunk (read-bytes-line in))
        (cond
          [(eof-object? chunk) '()]
          [else (cons (bytes->string/utf-8 chunk) (loop))]))))
  (close-input-port in)
  (string-join collected "\n"))

(let ()
  (define-values (port listener) (ephemeral-http-listener))
  (check-true (and (>= port 18432) (< port (+ 18432 512))))

  (define captured '())
  (define server
    (thread
     (lambda ()
       (serve-http! listener
                    (lambda (request)
                      (set! captured (cons request captured))
                      (cons "200 OK"
                            (string->bytes/utf-8
                             (format "{\"path\":\"~a\"}" (fake-request-path request)))))))))

  (define response (http-get port "/feed"))
  (check-true (regexp-match? #rx"HTTP/1.1 200 OK" response))
  (check-true (regexp-match? #rx"Connection: close" response))
  (check-true (regexp-match? #rx"\\{\"path\":\"/feed\"\\}" response))

  (kill-thread server)
  (tcp-close listener)
  (check-equal? (length captured) 1)
  (check-equal? (fake-request-method (car captured)) 'GET)
  (check-equal? (fake-request-path (car captured)) "/feed"))

;; POST with a body round-trips through the fake.
(let ()
  (define-values (port listener) (ephemeral-http-listener))
  (define captured #f)
  (define server
    (thread
     (lambda ()
       (serve-http! listener
                    (lambda (request)
                      (set! captured request)
                      (cons "201 Created" #"ok"))))))
  (define-values (in out) (tcp-connect "127.0.0.1" port))
  (define payload #"hello=fake")
  (display
   (format "POST /submit HTTP/1.1\r\nHost: t\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
           (bytes-length payload))
   out)
  (write-bytes payload out)
  (close-output-port out)
  ;; Give the fake a beat to process the request before tearing down.
  (sleep 0.2)
  (close-input-port in)
  (kill-thread server)
  (tcp-close listener)
  (check-equal? (fake-request-method captured) 'POST)
  (check-equal? (fake-request-body captured) payload))
