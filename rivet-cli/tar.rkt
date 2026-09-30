#lang racket/base

(require file/gzip
         racket/file
         racket/path
         racket/port
         racket/string)

(provide tar-directory->bytes
         gzip-archive-bytes)

;; Deterministic ustar archives for Linux installers. Two invocations over the
;; same package directory produce byte-identical output: entries are sorted,
;; ownership is pinned to root, modification times are pinned to the epoch,
;; and the gzip container carries no timestamp. Production verification
;; exploits this by rebuilding the archive from the packaged directory and
;; comparing bytes with the released installer.

(define ustar-block-size 512)
(define ustar-record-size 10240)

(define (numeric-field value digits)
  (unless (exact-nonnegative-integer? value)
    (raise-argument-error 'tar-directory->bytes
                          "exact-nonnegative-integer?" value))
  (define text (number->string value 8))
  (unless (<= (string-length text) digits)
    (raise-arguments-error 'tar-directory->bytes
                           "value does not fit the ustar octal field"
                           "value" value
                           "digits" digits))
  (bytes-append (make-bytes (- digits (string-length text)) (char->integer #\0))
                (string->bytes/latin-1 text)
                #"\0"))

(define (checksum-field value)
  (bytes-append (numeric-field value 6) #" "))

(define (split-entry-name relative)
  ;; ustar stores a long path as a 155-byte prefix and a 100-byte name joined
  ;; by a slash; short paths stay wholly inside the name field.
  (define encoded (string->bytes/utf-8 relative))
  (cond
    [(<= (bytes-length encoded) 100) (values encoded #"")]
    [else
     (define split
       (for/first ([index (in-list (reverse (slash-positions encoded)))]
                   #:when (and (<= index 155)
                               (<= (- (bytes-length encoded) index 1) 100)))
         index))
     (unless split
       (raise-arguments-error 'tar-directory->bytes
                              "entry name cannot be represented in ustar"
                              "entry" relative))
     (values (subbytes encoded (add1 split))
             (subbytes encoded 0 split))]))

(define (slash-positions encoded)
  (for/list ([byte (in-bytes encoded)]
             [index (in-naturals)]
             #:when (= byte (char->integer #\/)))
    index))

(define (ustar-header relative typeflag size mode)
  (define header (make-bytes ustar-block-size 0))
  (define-values (name prefix) (split-entry-name relative))
  (define (put offset value)
    (bytes-copy! header offset value 0 (bytes-length value)))
  (put 0 name)
  (put 100 (numeric-field mode 7))
  (put 108 (numeric-field 0 7))
  (put 116 (numeric-field 0 7))
  (put 124 (numeric-field size 11))
  (put 136 (numeric-field 0 11))
  (put 148 #"        ")
  (bytes-set! header 156 (char->integer typeflag))
  (put 257 (bytes-append #"ustar" (bytes 0)))
  (put 263 #"00")
  (put 345 prefix)
  (define checksum
    (for/fold ([sum 0]) ([byte (in-bytes header)]) (+ sum byte)))
  (put 148 (checksum-field checksum))
  header)

(define (entry-mode path)
  ;; Depending on the platform, the 'bits form reports a symbol list or an
  ;; integer bitmask; accept both.
  (define bits (file-or-directory-permissions path 'bits))
  (define executable?
    (if (list? bits)
        (memq 'execute bits)
        (positive? (bitwise-and bits #o111))))
  (if executable? #o755 #o644))

(define (archive-name relative)
  ;; Archive names always use forward slashes, independent of the host.
  (string-replace (path->string relative) "\\" "/"))

(define (collect-entries root)
  (sort
   (for/list ([path (in-list (find-files (lambda (_) #t) root))]
              #:unless (equal? path root))
     (cons (archive-name (find-relative-path root path))
           (find-relative-path root path)))
   string<?
   #:key car))

(define (tar-directory->bytes root #:root-name [root-name #f])
  (unless (directory-exists? root)
    (raise-argument-error 'tar-directory->bytes "directory-exists?" root))
  (define (archive-entry-name relative)
    (if root-name
        (string-append root-name "/" relative)
        relative))
  (call-with-output-bytes
   (lambda (out)
     (for ([entry (in-list (collect-entries root))])
       (define relative (archive-entry-name (car entry)))
       (define path (build-path root (cdr entry)))
       (cond
         [(link-exists? path)
          (raise-arguments-error
           'tar-directory->bytes
           "package contains a symbolic link; Rivet packages must be plain files and directories"
           "entry" relative)]
         [(directory-exists? path)
          (write-bytes (ustar-header relative #\5 0 #o755) out)]
         [else
          (define payload (file->bytes path))
          (write-bytes (ustar-header relative #\0
                                     (bytes-length payload)
                                     (entry-mode path))
                       out)
          (write-bytes payload out)
          (define padding (remainder (bytes-length payload) ustar-block-size))
          (unless (zero? padding)
            (write-bytes (make-bytes (- ustar-block-size padding)) out))]))
     (write-bytes (make-bytes (* 2 ustar-block-size)) out)
     (define tail (remainder (file-position out) ustar-record-size))
     (unless (zero? tail)
       (write-bytes (make-bytes (- ustar-record-size tail)) out)))))

(define (gzip-archive-bytes payload)
  ;; A fixed empty original name and epoch timestamp keep the gzip container
  ;; byte-stable; the deflate payload itself is already deterministic.
  (define out (open-output-bytes))
  (call-with-input-bytes payload
    (lambda (in)
      (gzip-through-ports in out #f 0)))
  (get-output-bytes out))
